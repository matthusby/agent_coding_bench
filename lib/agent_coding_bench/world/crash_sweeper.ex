defmodule AgentCodingBench.World.CrashSweeper do
  @moduledoc false

  use GenServer, restart: :permanent

  alias AgentCodingBench.World.CrashSweep

  @doc false
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Waits until global crash recovery has completed successfully."
  @spec await_ready(GenServer.server()) :: :ok
  def await_ready(server \\ __MODULE__) do
    GenServer.call(server, :await_ready, :infinity)
  end

  @impl true
  def init(opts), do: {:ok, %{opts: opts, ready?: false, waiters: []}, {:continue, :sweep}}

  @impl true
  def handle_call(:await_ready, _from, %{ready?: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:await_ready, from, state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  @impl true
  def handle_continue(:sweep, state) do
    opts = state.opts

    case CrashSweep.run(
           :all,
           Keyword.fetch!(opts, :repos),
           Keyword.fetch!(opts, :clone_root),
           Keyword.fetch!(opts, :exec)
         ) do
      :ok ->
        Enum.each(state.waiters, &GenServer.reply(&1, :ok))
        {:noreply, %{state | ready?: true, waiters: []}}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end
end
