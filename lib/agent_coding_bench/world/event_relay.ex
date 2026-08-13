defmodule AgentCodingBench.World.EventRelay do
  @moduledoc """
  Routes opencode events to the lane registered for each Coder session.

  Lanes register their opencode session ID in
  `AgentCodingBench.World.SessionRegistry` and receive
  `{:coder_event, event}` messages from the relay.
  """

  use GenServer

  alias AgentCodingBench.Coder
  alias AgentCodingBench.World.SessionRegistry

  @doc false
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      client: Keyword.get_lazy(opts, :client, fn -> Coder.client(nil) end),
      coder: Keyword.get(opts, :coder, Coder),
      reconnect_delay: Keyword.get(opts, :reconnect_delay, 1_000),
      recovering?: false,
      registry: Keyword.get(opts, :registry, SessionRegistry),
      stream: nil
    }

    {:ok, state, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        consume_stream(parent, ref, state.coder, state.client)
      end)

    {:noreply, %{state | stream: %{pid: pid, monitor: monitor, ref: ref}}}
  end

  @impl true
  def handle_info(
        {:stream_event, ref, %{"type" => "server.connected"} = event},
        %{stream: %{ref: ref}, recovering?: true} = state
      ) do
    route_event(event, state.registry)
    refresh_pending(state)
    {:noreply, %{state | recovering?: false}}
  end

  def handle_info({:stream_event, ref, event}, %{stream: %{ref: ref}} = state) do
    route_event(event, state.registry)
    {:noreply, state}
  end

  def handle_info({:stream_closed, ref, reason}, %{stream: %{ref: ref}} = state) do
    Process.demonitor(state.stream.monitor, [:flush])
    {:noreply, recover(state, reason)}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{stream: %{monitor: monitor}} = state
      ) do
    {:noreply, recover(state, reason)}
  end

  def handle_info(:subscribe, state) do
    {:noreply, state, {:continue, :subscribe}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{stream: %{pid: pid}}) do
    Process.exit(pid, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp consume_stream(parent, ref, coder, client) do
    result =
      case coder.event_stream(client) do
        {:ok, stream} ->
          Enum.reduce_while(stream, :closed, fn
            {:error, reason}, _acc ->
              {:halt, reason}

            event, acc ->
              send(parent, {:stream_event, ref, event})
              {:cont, acc}
          end)

        {:error, reason} ->
          reason
      end

    send(parent, {:stream_closed, ref, result})
  end

  defp refresh_pending(state) do
    state.coder.pending_questions(state.client)
    |> route_pending("question.asked", state.registry)

    state.coder.pending_permissions(state.client)
    |> route_pending("permission.asked", state.registry)
  end

  defp recover(state, _reason) do
    Process.send_after(self(), :subscribe, state.reconnect_delay)
    %{state | recovering?: true, stream: nil}
  end

  defp route_pending({:ok, requests}, type, registry) do
    for request <- requests do
      route_event(%{"type" => type, "properties" => request}, registry)
    end
  end

  defp route_pending(_error, _type, _registry), do: :ok

  defp route_event(%{"properties" => %{"sessionID" => session_id}} = event, registry) do
    for {pid, _value} <- Registry.lookup(registry, session_id) do
      send(pid, {:coder_event, event})
    end
  end

  defp route_event(_event, _registry), do: :ok
end
