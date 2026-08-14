defmodule AgentCodingBench.Coder.Client do
  @moduledoc """
  opencode SDK transport with a working global SSE stream.

  Ordinary generated-client requests delegate unchanged. The global event
  feed stays here because opencode_sdk 0.1.88's stream worker sends chunks to
  itself instead of its consumer.
  """

  @global_event_path "/global/event"

  def request(%{method: :get, url: @global_event_path} = params) do
    opts = Map.get(params, :opts, [])
    runner = Keyword.get_lazy(opts, :event_stream_runner, fn -> request_runner(opts) end)
    {:ok, %{stream: event_stream(runner)}}
  end

  def request(params), do: OpenCode.Client.request(params)

  defp event_stream(runner) do
    Stream.resource(
      fn ->
        parent = self()
        ref = make_ref()

        pid =
          spawn_link(fn ->
            result = runner.(fn data -> send(parent, {ref, :data, data}) end)
            send(parent, {ref, :done, result})
          end)

        %{buffer: "", done?: false, pid: pid, ref: ref}
      end,
      &next_events/1,
      &stop_runner/1
    )
  end

  defp next_events(%{done?: true} = state), do: {:halt, state}

  defp next_events(state) do
    receive do
      {ref, :data, data} when ref == state.ref ->
        {events, buffer} = decode_chunk(state.buffer <> data)
        {events, %{state | buffer: buffer}}

      {ref, :done, :ok} when ref == state.ref ->
        events = decode_final(state.buffer)
        {events, %{state | buffer: "", done?: true}}

      {ref, :done, {:error, reason}} when ref == state.ref ->
        {[{:error, reason}], %{state | done?: true}}
    end
  end

  defp stop_runner(state) do
    if Process.alive?(state.pid), do: Process.exit(state.pid, :shutdown)
  end

  defp request_runner(opts) do
    fn emit ->
      opts
      |> build_request()
      |> Req.request(
        into: fn {:data, data}, acc ->
          emit.(data)
          {:cont, acc}
        end
      )
      |> case do
        {:ok, _response} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp build_request(opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    receive_timeout = Keyword.get(opts, :timeout, :infinity)

    request =
      Req.new(url: base_url <> @global_event_path, receive_timeout: receive_timeout)
      |> Req.Request.put_header("accept", "text/event-stream")

    Enum.reduce(Keyword.get(opts, :headers, []), request, fn {key, value}, acc ->
      Req.Request.put_header(acc, to_string(key), to_string(value))
    end)
  end

  defp decode_chunk(data) do
    parts = data |> String.replace("\r\n", "\n") |> String.split("\n\n")
    {complete, [buffer]} = Enum.split(parts, -1)
    {Enum.flat_map(complete, &decode_event/1), buffer}
  end

  defp decode_final(buffer) do
    if String.trim(buffer) == "", do: [], else: decode_event(buffer)
  end

  defp decode_event(chunk) do
    data =
      chunk
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("\n", &String.trim_leading(&1, "data:"))
      |> String.trim()

    case Jason.decode(data) do
      {:ok, event} -> [event]
      {:error, _reason} -> []
    end
  end
end
