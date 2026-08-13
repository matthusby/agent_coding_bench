defmodule AgentCodingBench.World.LaneSupervisor do
  @moduledoc """
  Dynamically owns the World's permanent Lane processes.
  """

  use DynamicSupervisor

  alias AgentCodingBench.World.Lane
  alias AgentCodingBench.World.SessionRegistry

  @doc false
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> DynamicSupervisor.start_link(__MODULE__, opts)
      name -> DynamicSupervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Makes the live Lane set exactly `0..lane_count-1`."
  @spec scale(DynamicSupervisor.supervisor(), non_neg_integer()) :: :ok | {:error, term()}
  def scale(supervisor \\ __MODULE__, lane_count, opts \\ [])
      when is_integer(lane_count) and lane_count >= 0 do
    settings = %{
      lane: Keyword.get(opts, :lane, Lane),
      lane_opts: Keyword.get(opts, :lane_opts, configured_lane_opts()),
      registry: Keyword.get(opts, :registry, SessionRegistry)
    }

    current = lanes_for_registry(supervisor, settings.registry)
    desired = if lane_count == 0, do: [], else: Enum.to_list(0..(lane_count - 1))

    with :ok <- stop_lanes(supervisor, current -- desired, settings.registry),
         :ok <- start_lanes(supervisor, desired -- current, settings) do
      :ok
    end
  end

  @doc "Returns live Lane numbers in ascending order."
  @spec lanes(DynamicSupervisor.supervisor()) :: [non_neg_integer()]
  def lanes(supervisor \\ __MODULE__, registry \\ SessionRegistry) do
    lanes_for_registry(supervisor, registry)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  defp lanes_for_registry(supervisor, registry) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn {_id, pid, _type, _modules} ->
      case Registry.keys(registry, pid) do
        [{:lane, lane}] -> [lane]
        _keys -> []
      end
    end)
    |> Enum.sort()
  end

  defp stop_lanes(supervisor, lane_numbers, registry) do
    lane_numbers
    |> Enum.sort(:desc)
    |> Enum.reduce_while(:ok, fn lane, :ok ->
      case Registry.lookup(registry, {:lane, lane}) do
        [{pid, _value}] ->
          case DynamicSupervisor.terminate_child(supervisor, pid) do
            :ok ->
              Phoenix.PubSub.broadcast(
                AgentCodingBench.PubSub,
                "world",
                {:lane_removed, lane}
              )

              {:cont, :ok}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        [] ->
          {:cont, :ok}
      end
    end)
  end

  defp start_lanes(supervisor, lane_numbers, settings) do
    Enum.reduce_while(lane_numbers, :ok, fn lane, :ok ->
      name = {:via, Registry, {settings.registry, {:lane, lane}}}
      child_opts = Keyword.merge(settings.lane_opts, lane: lane, name: name)

      case DynamicSupervisor.start_child(supervisor, {settings.lane, child_opts}) do
        {:ok, _pid} -> {:cont, :ok}
        {:error, {:already_started, _pid}} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp configured_lane_opts do
    Application.get_env(:agent_coding_bench, AgentCodingBench.World.Lane, [])
  end
end
