defmodule AgentCodingBench.Stats.Comparison do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias AgentCodingBench.Repo
  alias AgentCodingBench.Stats.Call
  alias AgentCodingBench.Stats.Run
  alias AgentCodingBench.Stats.Serving
  alias AgentCodingBench.World

  @spec build(Run.t(), Run.t()) :: map()
  def build(%Run{} = run_a, %Run{} = run_b) do
    run_a_data = Serving.for_window(run_a.started_at, run_end(run_a))
    run_b_data = Serving.for_window(run_b.started_at, run_end(run_b))
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

  defp config_match?(run_a, run_b) do
    run_a.fingerprint_digest == run_b.fingerprint_digest and not run_a.fingerprint_mismatch and
      not run_b.fingerprint_mismatch
  end

  defp duration_seconds(run), do: DateTime.diff(run_end(run), run.started_at)
  defp run_end(%Run{ended_at: nil}), do: DateTime.utc_now()
  defp run_end(%Run{ended_at: ended_at}), do: ended_at

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
