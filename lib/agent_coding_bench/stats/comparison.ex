defmodule AgentCodingBench.Stats.Comparison do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias AgentCodingBench.Repo
  alias AgentCodingBench.Stats.Call
  alias AgentCodingBench.Stats.Run
  alias AgentCodingBench.Stats.Sample
  alias AgentCodingBench.World

  @generation "vllm:generation_tokens_total"
  @running "vllm:num_requests_running"
  @waiting "vllm:num_requests_waiting"
  @kv_cache "vllm:kv_cache_usage_perc"
  @ttft "vllm:time_to_first_token_seconds_bucket"
  @itl "vllm:inter_token_latency_seconds_bucket"
  @serving_metrics [@generation, @running, @waiting, @kv_cache, @ttft, @itl]

  @spec build(Run.t(), Run.t()) :: map()
  def build(%Run{} = run_a, %Run{} = run_b) do
    run_a_data = serving_data(run_a)
    run_b_data = serving_data(run_b)
    workload_a = workload_data(run_a)
    workload_b = workload_data(run_b)

    %{
      runs: %{a: run_a, b: run_b},
      config_match?: config_match?(run_a, run_b),
      max_duration_seconds: max(duration_seconds(run_a), duration_seconds(run_b)),
      metrics: metric_rows(run_a_data, run_b_data),
      workload: workload_rows(workload_a, workload_b)
    }
  end

  defp serving_data(run) do
    samples =
      Repo.all(
        from sample in Sample,
          where:
            sample.scraped_at >= ^run.started_at and sample.scraped_at <= ^run_end(run) and
              sample.metric in ^@serving_metrics,
          order_by: [asc: sample.scraped_at]
      )

    %{
      generation: counter_rate_series(samples, @generation, run),
      running: gauge_series(samples, @running, run, :sum, 1),
      waiting: gauge_series(samples, @waiting, run, :sum, 1),
      kv_cache: gauge_series(samples, @kv_cache, run, :average, 100),
      ttft_p50: histogram_quantile_series(samples, @ttft, run, 0.50, 1),
      ttft_p99: histogram_quantile_series(samples, @ttft, run, 0.99, 1),
      itl_p50: histogram_quantile_series(samples, @itl, run, 0.50, 1_000),
      itl_p99: histogram_quantile_series(samples, @itl, run, 0.99, 1_000)
    }
  end

  defp metric_rows(a, b) do
    [
      metric_row(
        :generation_throughput,
        "Generation throughput",
        "tok/s",
        "median",
        :up,
        %{generation: a.generation},
        %{generation: b.generation},
        &median(&1.generation)
      ),
      metric_row(
        :ttft,
        "Time to first token",
        "s",
        "median p99",
        :down,
        %{p50: a.ttft_p50, p99: a.ttft_p99},
        %{p50: b.ttft_p50, p99: b.ttft_p99},
        &median(&1.p99)
      ),
      metric_row(
        :itl,
        "Inter-token latency",
        "ms",
        "median p99",
        :down,
        %{p50: a.itl_p50, p99: a.itl_p99},
        %{p50: b.itl_p50, p99: b.itl_p99},
        &median(&1.p99)
      ),
      metric_row(
        :requests,
        "Requests running / waiting",
        "requests",
        "peak waiting",
        :down,
        %{running: a.running, waiting: a.waiting},
        %{running: b.running, waiting: b.waiting},
        &max_value(&1.waiting)
      ),
      metric_row(
        :kv_cache,
        "KV-cache usage",
        "%",
        "peak",
        :down,
        %{usage: a.kv_cache},
        %{usage: b.kv_cache},
        &max_value(&1.usage)
      )
    ]
  end

  defp workload_data(run) do
    first = run.started_at
    last = run_end(run)
    world_workload = World.workload_for_window(first, last)

    coder_turns =
      Repo.one(
        from call in Call,
          where:
            call.task_id in ^world_workload.task_ids and call.role == "coder" and
              call.at >= ^first and call.at <= ^last,
          select: count(call.id)
      )

    duration_hours = duration_seconds(run) / 3_600

    %{
      tasks_started: world_workload.tasks_started,
      merged: world_workload.merged,
      abandoned: world_workload.abandoned,
      tasks_per_hour:
        if(duration_hours > 0,
          do: world_workload.tasks_started / duration_hours,
          else: nil
        ),
      review_cycles_per_task: ratio(world_workload.review_cycles, world_workload.tasks_started),
      coder_turns_per_task: ratio(coder_turns, world_workload.tasks_started)
    }
  end

  defp workload_rows(a, b) do
    [
      workload_row(:tasks_started, "Tasks started", a, b),
      workload_row(:merged, "Merged", a, b),
      workload_row(:abandoned, "Abandoned", a, b),
      workload_row(:tasks_per_hour, "Tasks / hour", a, b),
      workload_row(:review_cycles_per_task, "Review cycles / Task", a, b),
      workload_row(:coder_turns_per_task, "Coder turns / Task", a, b)
    ]
  end

  defp workload_row(key, label, a, b) do
    %{key: key, label: label, a: Map.fetch!(a, key), b: Map.fetch!(b, key)}
  end

  defp ratio(_numerator, 0), do: nil
  defp ratio(numerator, denominator), do: numerator / denominator

  defp metric_row(key, title, unit, summary_label, better, lines_a, lines_b, summarize) do
    summary_lines_a = Map.new(lines_a, fn {name, points} -> {name, steady(points)} end)
    summary_lines_b = Map.new(lines_b, fn {name, points} -> {name, steady(points)} end)

    %{
      key: key,
      title: title,
      unit: unit,
      summary_label: summary_label,
      better: better,
      a: %{lines: lines_a, summary: summarize.(summary_lines_a)},
      b: %{lines: lines_b, summary: summarize.(summary_lines_b)}
    }
  end

  defp counter_rate_series(samples, metric, run) do
    samples
    |> Enum.filter(&(&1.metric == metric))
    |> Enum.group_by(& &1.labels)
    |> Enum.flat_map(fn {_labels, series} ->
      series
      |> Enum.sort_by(& &1.scraped_at, DateTime)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [previous, current] ->
        elapsed = DateTime.diff(current.scraped_at, previous.scraped_at, :microsecond) / 1_000_000

        if elapsed > 0 do
          increase = counter_increase(previous.value, current.value)

          [%{at: current.scraped_at, value: increase / elapsed}]
        else
          []
        end
      end)
    end)
    |> aggregate_at(:sum)
    |> align_to_run(run)
  end

  defp gauge_series(samples, metric, run, aggregation, multiplier) do
    samples
    |> Enum.filter(&(&1.metric == metric))
    |> Enum.map(&%{at: &1.scraped_at, value: &1.value * multiplier})
    |> aggregate_at(aggregation)
    |> align_to_run(run)
  end

  defp histogram_quantile_series(samples, metric, run, quantile, multiplier) do
    samples
    |> Enum.filter(&(&1.metric == metric))
    |> Enum.group_by(&Map.delete(&1.labels, "le"))
    |> Enum.flat_map(fn {_labels, family_samples} -> histogram_increases(family_samples) end)
    |> Enum.group_by(& &1.at, & &1.buckets)
    |> Enum.flat_map(fn {at, bucket_sets} ->
      buckets =
        Enum.reduce(bucket_sets, %{}, fn bucket_set, totals ->
          Map.merge(totals, bucket_set, fn _bound, left, right -> left + right end)
        end)

      if Map.get(buckets, :infinity, 0.0) > 0 do
        [%{at: at, value: histogram_quantile(buckets, quantile) * multiplier}]
      else
        []
      end
    end)
    |> Enum.sort_by(& &1.at, DateTime)
    |> align_to_run(run)
  end

  defp histogram_increases(samples) do
    samples
    |> Enum.group_by(& &1.scraped_at)
    |> Enum.map(fn {at, snapshot_samples} ->
      buckets = Map.new(snapshot_samples, &{parse_bound(&1.labels["le"]), &1.value})
      %{at: at, buckets: buckets}
    end)
    |> Enum.sort_by(& &1.at, DateTime)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [previous, current] ->
      buckets =
        Map.new(current.buckets, fn {bound, current_count} ->
          previous_count = Map.get(previous.buckets, bound, 0.0)

          {bound, counter_increase(previous_count, current_count)}
        end)

      %{at: current.at, buckets: buckets}
    end)
  end

  defp histogram_quantile(buckets, quantile) do
    total = Map.get(buckets, :infinity, 0.0)
    rank = quantile * total

    buckets
    |> Enum.reject(fn {bound, _count} -> bound == :infinity end)
    |> Enum.sort_by(&elem(&1, 0))
    |> interpolate_quantile(rank, 0.0, 0.0)
  end

  defp interpolate_quantile([], _rank, lower_bound, _lower_count), do: lower_bound

  defp interpolate_quantile([{upper_bound, count} | rest], rank, lower_bound, lower_count) do
    if count >= rank do
      observations = count - lower_count

      if observations > 0 do
        lower_bound + (upper_bound - lower_bound) * (rank - lower_count) / observations
      else
        upper_bound
      end
    else
      interpolate_quantile(rest, rank, upper_bound, count)
    end
  end

  defp parse_bound("+Inf"), do: :infinity

  defp parse_bound(bound) do
    {value, ""} = Float.parse(bound)
    value
  end

  defp aggregate_at(points, aggregation) do
    points
    |> Enum.group_by(& &1.at, & &1.value)
    |> Enum.map(fn {at, values} ->
      value =
        case aggregation do
          :sum -> Enum.sum(values)
          :average -> Enum.sum(values) / length(values)
        end

      %{at: at, value: value}
    end)
    |> Enum.sort_by(& &1.at, DateTime)
  end

  defp align_to_run(points, run) do
    Enum.map(points, fn point ->
      %{offset_seconds: DateTime.diff(point.at, run.started_at), value: point.value}
    end)
  end

  defp config_match?(run_a, run_b) do
    run_a.fingerprint_digest == run_b.fingerprint_digest and not run_a.fingerprint_mismatch and
      not run_b.fingerprint_mismatch
  end

  defp duration_seconds(run), do: DateTime.diff(run_end(run), run.started_at)
  defp run_end(%Run{ended_at: nil}), do: DateTime.utc_now()
  defp run_end(%Run{ended_at: ended_at}), do: ended_at

  defp counter_increase(previous, current) when current >= previous, do: current - previous
  defp counter_increase(_previous, current), do: current

  defp steady(points), do: Enum.drop(points, div(length(points), 10))

  defp median([]), do: nil

  defp median(points) do
    values = points |> Enum.map(& &1.value) |> Enum.sort()
    middle = div(length(values), 2)

    if rem(length(values), 2) == 0 do
      (Enum.at(values, middle - 1) + Enum.at(values, middle)) / 2
    else
      Enum.at(values, middle)
    end
  end

  defp max_value([]), do: nil
  defp max_value(points), do: points |> Enum.map(& &1.value) |> Enum.max()
end
