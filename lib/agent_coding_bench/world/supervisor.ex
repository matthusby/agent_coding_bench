defmodule AgentCodingBench.World.Supervisor do
  @moduledoc """
  Owns every process whose lifetime defines the World being up.
  """

  use Supervisor

  alias AgentCodingBench.Stats.Collector
  alias AgentCodingBench.World.CrashSweeper
  alias AgentCodingBench.World.EventRelay
  alias AgentCodingBench.World.LaneSupervisor

  @doc false
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> Supervisor.start_link(__MODULE__, opts)
      name -> Supervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    lane_config = Application.fetch_env!(:agent_coding_bench, AgentCodingBench.World.Lane)
    repos = Keyword.get(opts, :repos, Keyword.fetch!(lane_config, :repos))
    clone_root = Keyword.get(opts, :clone_root, Keyword.fetch!(lane_config, :clone_root))
    exec = Keyword.get(opts, :exec, &AgentCodingBench.Box.exec/2)

    children =
      [
        child(Keyword.get(opts, :collector, Collector), Keyword.get(opts, :collector_opts, [])),
        child(
          Keyword.get(opts, :event_relay, EventRelay),
          Keyword.get(opts, :event_relay_opts, [])
        ),
        child(
          Keyword.get(opts, :lane_supervisor, LaneSupervisor),
          Keyword.get(opts, :lane_supervisor_opts, [])
        ),
        {CrashSweeper, name: CrashSweeper, repos: repos, clone_root: clone_root, exec: exec}
      ]
      |> Enum.reject(&is_nil/1)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp child(false, _opts), do: nil
  defp child(module, opts), do: {module, opts}
end
