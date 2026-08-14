defmodule AgentCodingBench.Stats.Serving do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias AgentCodingBench.Repo
  alias AgentCodingBench.Stats.Sample

  @prompt "vllm:prompt_tokens_total"
  @prompt_cached "vllm:prompt_tokens_cached_total"
  @generation "vllm:generation_tokens_total"
  @prefix_cache_hits "vllm:prefix_cache_hits_total"
  @prefix_cache_queries "vllm:prefix_cache_queries_total"
  @running "vllm:num_requests_running"
  @waiting "vllm:num_requests_waiting"
  @kv_cache "vllm:kv_cache_usage_perc"
  @prefill "vllm:request_prefill_time_seconds_bucket"
  @ttft "vllm:time_to_first_token_seconds_bucket"
  @itl "vllm:inter_token_latency_seconds_bucket"
  @serving_metrics [
    @prompt,
    @prompt_cached,
    @generation,
    @prefix_cache_hits,
    @prefix_cache_queries,
    @running,
    @waiting,
    @kv_cache,
    @prefill,
    @ttft,
    @itl
  ]

  @spec for_window(DateTime.t(), DateTime.t()) :: map()
  def for_window(%DateTime{} = started_at, %DateTime{} = ended_at) do
    samples =
      Repo.all(
        from sample in Sample,
          where:
            sample.scraped_at >= ^started_at and sample.scraped_at <= ^ended_at and
              sample.metric in ^@serving_metrics,
          order_by: [asc: sample.scraped_at]
      )

    %{
      prompt: counter_rate_series(samples, @prompt, started_at),
      generation: counter_rate_series(samples, @generation, started_at),
      prompt_cache_hit: counter_ratio_series(samples, @prompt_cached, @prompt, started_at, 100),
      prefix_cache_hit:
        counter_ratio_series(
          samples,
          @prefix_cache_hits,
          @prefix_cache_queries,
          started_at,
          100
        ),
      running: gauge_series(samples, @running, started_at, :sum, 1),
      waiting: gauge_series(samples, @waiting, started_at, :sum, 1),
      kv_cache: gauge_series(samples, @kv_cache, started_at, :average, 100),
      prefill_p50: histogram_quantile_series(samples, @prefill, started_at, 0.50, 1),
      prefill_p99: histogram_quantile_series(samples, @prefill, started_at, 0.99, 1),
      ttft_p50: histogram_quantile_series(samples, @ttft, started_at, 0.50, 1),
      ttft_p99: histogram_quantile_series(samples, @ttft, started_at, 0.99, 1),
      itl_p50: histogram_quantile_series(samples, @itl, started_at, 0.50, 1_000),
      itl_p99: histogram_quantile_series(samples, @itl, started_at, 0.99, 1_000)
    }
  end

  defp counter_rate_series(samples, metric, started_at) do
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
    |> align_to_window(started_at)
  end

  defp counter_ratio_series(samples, numerator_metric, denominator_metric, started_at, multiplier) do
    numerator_by_at =
      samples
      |> counter_delta_series(numerator_metric)
      |> Map.new(&{&1.at, &1.value})

    samples
    |> counter_delta_series(denominator_metric)
    |> Enum.flat_map(fn %{at: at, value: denominator} ->
      if denominator > 0 do
        [%{at: at, value: Map.get(numerator_by_at, at, 0.0) / denominator * multiplier}]
      else
        []
      end
    end)
    |> align_to_window(started_at)
  end

  defp counter_delta_series(samples, metric) do
    samples
    |> Enum.filter(&(&1.metric == metric))
    |> Enum.group_by(& &1.labels)
    |> Enum.flat_map(fn {_labels, series} ->
      series
      |> Enum.sort_by(& &1.scraped_at, DateTime)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [previous, current] ->
        %{at: current.scraped_at, value: counter_increase(previous.value, current.value)}
      end)
    end)
    |> aggregate_at(:sum)
  end

  defp gauge_series(samples, metric, started_at, aggregation, multiplier) do
    samples
    |> Enum.filter(&(&1.metric == metric))
    |> Enum.map(&%{at: &1.scraped_at, value: &1.value * multiplier})
    |> aggregate_at(aggregation)
    |> align_to_window(started_at)
  end

  defp histogram_quantile_series(samples, metric, started_at, quantile, multiplier) do
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
    |> align_to_window(started_at)
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

  defp align_to_window(points, started_at) do
    Enum.map(points, fn point ->
      %{offset_seconds: DateTime.diff(point.at, started_at), value: point.value}
    end)
  end

  defp counter_increase(previous, current) when current >= previous, do: current - previous
  defp counter_increase(_previous, current), do: current
end
