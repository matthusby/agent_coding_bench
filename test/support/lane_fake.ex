defmodule AgentCodingBench.LaneFake do
  @moduledoc false

  use GenServer, restart: :permanent

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @impl true
  def init(opts) do
    send(Keyword.fetch!(opts, :test_pid), {:lane_started, Keyword.fetch!(opts, :lane), self()})
    {:ok, opts}
  end
end
