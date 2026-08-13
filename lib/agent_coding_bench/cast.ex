defmodule AgentCodingBench.Cast do
  @moduledoc """
  Completion boundary for the PM, Reviewer, and Person.

  Responses stream directly from vLLM so client-observed time to first token
  and total duration can be stored with token usage in `Stats.Call`.
  """

  alias AgentCodingBench.Box
  alias AgentCodingBench.Stats

  @roles [:pm, :reviewer, :person]
  @stream_key :agent_coding_bench_cast_stream

  @type message :: %{required(:role) => String.t(), required(:content) => String.t()}
  @type context :: %{
          required(:lane) => non_neg_integer(),
          required(:role) => :pm | :reviewer | :person,
          optional(:task_id) => integer() | nil
        }
  @type result :: {:ok, String.t()} | {:error, term()}

  @callback complete([message()], context(), keyword()) :: result()

  @doc "Runs one completion and records its client-observed metrics."
  @spec complete([message()], context(), keyword()) :: result()
  def complete(messages, %{lane: lane, role: role} = context, opts \\ [])
      when is_list(messages) and is_integer(lane) and lane >= 0 and role in @roles do
    request = Keyword.get(opts, :request, &Req.request/1)
    vllm_url = opts |> vllm_url() |> String.trim_trailing("/")
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)

    with {:ok, model} <- model(request, vllm_url, opts) do
      started_at = DateTime.utc_now()
      started_ms = clock.()

      with {:ok, content, usage, first_token_ms, finished_ms} <-
             request_completion(request, vllm_url, model, messages, opts, clock),
           {:ok, _call} <-
             Stats.record_call(%{
               at: started_at,
               lane: lane,
               role: Atom.to_string(role),
               task_id: Map.get(context, :task_id),
               prompt_tokens: usage.prompt_tokens,
               completion_tokens: usage.completion_tokens,
               reasoning_tokens: usage.reasoning_tokens,
               cached_tokens: usage.cached_tokens,
               ttft_ms: elapsed(first_token_ms, started_ms),
               duration_ms: max(finished_ms - started_ms, 0)
             }) do
        if content == "", do: {:error, :empty_completion}, else: {:ok, content}
      end
    end
  end

  defp vllm_url(opts) do
    case Keyword.fetch(opts, :vllm_url) do
      {:ok, url} -> url
      :error -> Box.vllm_url()
    end
  end

  defp model(request, vllm_url, opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) ->
        {:ok, model}

      nil ->
        discover_model(request, vllm_url)
    end
  end

  defp discover_model(request, vllm_url) do
    url = vllm_url <> "/v1/models"

    case request.(method: :get, url: url, retry: :safe_transient) do
      {:ok, %{status: status, body: %{"data" => [%{"id" => model} | _]}}}
      when status in 200..299 and is_binary(model) ->
        {:ok, model}

      {:ok, %{status: status, body: body}} ->
        {:error, {:model_discovery, status, body}}

      {:error, reason} ->
        {:error, {:model_discovery, reason}}
    end
  end

  defp request_completion(request, vllm_url, model, messages, opts, clock) do
    initial = %{buffer: "", content: [], first_token_ms: nil, usage: nil}

    into = fn {:data, data}, {req, response} ->
      state = Req.Response.get_private(response, @stream_key, initial)
      state = consume(state, data, clock)
      response = Req.Response.put_private(response, @stream_key, state)
      {:cont, {req, response}}
    end

    body =
      %{
        "model" => model,
        "messages" => messages,
        "stream" => true,
        "stream_options" => %{"include_usage" => true}
      }
      |> maybe_put("response_format", Keyword.get(opts, :response_format))

    result =
      request.(
        method: :post,
        url: vllm_url <> "/v1/chat/completions",
        json: body,
        into: into,
        retry: :transient,
        max_retries: 2,
        receive_timeout: :infinity
      )

    finished_ms = clock.()

    case result do
      {:ok, %{status: status} = response} when status in 200..299 ->
        response
        |> Req.Response.get_private(@stream_key, initial)
        |> finish(clock, finished_ms)

      {:ok, %{status: status} = response} ->
        state = Req.Response.get_private(response, @stream_key, initial)
        {:error, {:completion_http, status, state.buffer}}

      {:error, reason} ->
        {:error, {:completion_http, reason}}
    end
  end

  defp consume(state, data, clock) when is_binary(data) do
    parts =
      state.buffer
      |> Kernel.<>(data)
      |> String.replace("\r\n", "\n")
      |> String.split("\n\n")

    {events, [buffer]} = Enum.split(parts, -1)
    state = %{state | buffer: buffer}
    Enum.reduce(events, state, &consume_event(&2, &1, clock))
  end

  defp finish(state, clock, finished_ms) do
    state =
      if String.trim(state.buffer) == "" do
        state
      else
        consume_event(%{state | buffer: ""}, state.buffer, clock)
      end

    with {:ok, usage} <- require_usage(state.usage) do
      content = state.content |> Enum.reverse() |> Enum.join()
      {:ok, content, usage, state.first_token_ms, finished_ms}
    end
  end

  defp consume_event(state, event, clock) do
    data =
      event
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("\n", fn line -> line |> String.trim_leading("data:") |> String.trim() end)

    case data do
      "" -> state
      "[DONE]" -> state
      json -> decode_event(state, json, clock)
    end
  end

  defp decode_event(state, json, clock) do
    case Jason.decode(json) do
      {:ok, event} ->
        content = delta_text(event)
        token_seen? = content != "" or reasoning_text(event) != ""

        state
        |> maybe_add_content(content)
        |> maybe_mark_first_token(token_seen?, clock)
        |> maybe_put_usage(event)

      {:error, _reason} ->
        state
    end
  end

  defp delta_text(%{"choices" => [%{"delta" => %{"content" => content}} | _]})
       when is_binary(content),
       do: content

  defp delta_text(_event), do: ""

  defp reasoning_text(%{"choices" => [%{"delta" => delta} | _]}) when is_map(delta) do
    Map.get(delta, "reasoning_content") || Map.get(delta, "reasoning") || ""
  end

  defp reasoning_text(_event), do: ""

  defp maybe_add_content(state, ""), do: state
  defp maybe_add_content(state, content), do: %{state | content: [content | state.content]}

  defp maybe_mark_first_token(%{first_token_ms: nil} = state, true, clock),
    do: %{state | first_token_ms: clock.()}

  defp maybe_mark_first_token(state, _token_seen?, _clock), do: state

  defp maybe_put_usage(state, %{"usage" => usage}) when is_map(usage) do
    %{state | usage: usage(usage)}
  end

  defp maybe_put_usage(state, _event), do: state

  defp usage(usage) do
    %{
      prompt_tokens: Map.get(usage, "prompt_tokens", 0),
      completion_tokens: Map.get(usage, "completion_tokens", 0),
      reasoning_tokens: get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) || 0,
      cached_tokens: get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0
    }
  end

  defp require_usage(nil), do: {:error, :missing_completion_usage}
  defp require_usage(usage), do: {:ok, usage}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp elapsed(nil, _started_ms), do: nil
  defp elapsed(finished_ms, started_ms), do: max(finished_ms - started_ms, 0)
end
