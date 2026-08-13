defmodule AgentCodingBench.Stats.Metrics do
  @moduledoc """
  Parses the vLLM families from a Prometheus text exposition.
  """

  @sample_pattern ~r/\A(?<metric>[a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(?<labels>.*)\})?\s+(?<value>[^\s]+)(?:\s+[^\s]+)?\z/
  @label_pattern ~r/\A([a-zA-Z_][a-zA-Z0-9_]*)="((?:\\[\\n"]|[^"\\])*)"(?:,(.*))?\z/s

  @doc """
  Parses all and only samples whose metric name begins with `vllm:`.
  """
  @spec parse(String.t(), DateTime.t()) :: {:ok, [map()]} | {:error, term()}
  def parse(exposition, %DateTime{} = scraped_at) when is_binary(exposition) do
    exposition
    |> String.split("\n")
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, samples} ->
      line = String.trim(line)

      cond do
        not String.starts_with?(line, "vllm:") ->
          {:cont, {:ok, samples}}

        true ->
          case parse_sample(line, scraped_at) do
            {:ok, sample} -> {:cont, {:ok, [sample | samples]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, samples} -> {:ok, Enum.reverse(samples)}
      error -> error
    end
  end

  defp parse_sample(line, scraped_at) do
    with %{"metric" => metric, "labels" => labels_text, "value" => value_text} <-
           Regex.named_captures(@sample_pattern, line),
         {:ok, labels} <- parse_labels(labels_text),
         {:ok, value} <- parse_value(value_text) do
      {:ok, %{scraped_at: scraped_at, metric: metric, labels: labels, value: value}}
    else
      _ -> {:error, {:invalid_sample, line}}
    end
  end

  defp parse_labels(""), do: {:ok, %{}}

  defp parse_labels(labels_text) do
    parse_labels(labels_text, %{})
  end

  defp parse_labels("", labels), do: {:ok, labels}

  defp parse_labels(labels_text, labels) do
    case Regex.run(@label_pattern, labels_text) do
      [_, key, value, rest] ->
        parse_labels(rest, Map.put(labels, key, unescape_label(value)))

      [_, key, value] ->
        {:ok, Map.put(labels, key, unescape_label(value))}

      _ ->
        {:error, :invalid_labels}
    end
  end

  defp unescape_label(value) do
    Regex.replace(~r/\\([\\n"])/, value, fn
      _, "n" -> "\n"
      _, escaped -> escaped
    end)
  end

  defp parse_value(value_text) do
    case Float.parse(value_text) do
      {value, ""} -> {:ok, value}
      _ -> {:error, :invalid_value}
    end
  end
end
