defmodule AgentCodingBench.World do
  @moduledoc """
  Task persistence and runtime control for the living agent-coding world.
  """

  import Ecto.Query, only: [from: 2]

  alias AgentCodingBench.Repo
  alias AgentCodingBench.World.Lane
  alias AgentCodingBench.World.Task
  alias AgentCodingBench.World.TaskEvent
  alias AgentCodingBench.World.LaneSupervisor
  alias AgentCodingBench.World.RuntimeSupervisor
  alias AgentCodingBench.World.SessionRegistry
  alias AgentCodingBench.World.Supervisor, as: WorldSupervisor

  @doc "Starts the World and its requested number of Lanes."
  @spec start(non_neg_integer()) :: {:ok, pid()} | {:error, term()}
  def start(lane_count) when is_integer(lane_count) and lane_count >= 0 do
    case DynamicSupervisor.start_child(RuntimeSupervisor, {WorldSupervisor, []}) do
      {:ok, pid} ->
        case LaneSupervisor.scale(lane_count) do
          :ok ->
            broadcast_world_status(true, lane_count)
            {:ok, pid}

          {:error, reason} ->
            _ = DynamicSupervisor.terminate_child(RuntimeSupervisor, pid)
            {:error, reason}
        end

      {:error, {:already_started, pid}} ->
        {:error, {:already_started, pid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Hard-stops the World and every live Lane."
  @spec stop() :: :ok | {:error, :not_started}
  def stop do
    case Process.whereis(WorldSupervisor) do
      nil ->
        {:error, :not_started}

      pid ->
        lanes = LaneSupervisor.lanes()

        case DynamicSupervisor.terminate_child(RuntimeSupervisor, pid) do
          :ok ->
            Enum.each(lanes, fn lane ->
              Phoenix.PubSub.broadcast(
                AgentCodingBench.PubSub,
                "world",
                {:lane_removed, lane}
              )
            end)

            broadcast_world_status(false, 0)
            :ok

          {:error, _reason} = error ->
            error
        end
    end
  end

  @doc "Scales the running World without draining active Tasks."
  @spec scale_lanes(non_neg_integer()) :: :ok | {:error, :not_started | term()}
  def scale_lanes(lane_count) when is_integer(lane_count) and lane_count >= 0 do
    if Process.whereis(WorldSupervisor) do
      case LaneSupervisor.scale(lane_count) do
        :ok ->
          broadcast_world_status(true, lane_count)
          :ok

        {:error, _reason} = error ->
          error
      end
    else
      {:error, :not_started}
    end
  end

  @doc "Returns whether the ephemeral World supervisor is currently alive."
  @spec running?() :: boolean()
  def running?, do: Process.whereis(WorldSupervisor) != nil

  @doc "Returns the current observable status of every registered Lane."
  @spec lane_statuses() :: [Lane.status()]
  def lane_statuses do
    SessionRegistry
    |> Registry.select([{{{:lane, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {_lane, pid} ->
      try do
        [Lane.status(pid)]
      catch
        :exit, _reason -> []
      end
    end)
  end

  @doc "Creates the running Task row immediately after invention."
  @spec create_task(map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def create_task(attrs) when is_map(attrs) do
    attrs
    |> Task.create_changeset(DateTime.utc_now())
    |> Repo.insert()
  end

  @doc "Appends one Person-facing event to a Task transcript."
  @spec record_event(Task.t(), atom(), String.t()) ::
          {:ok, TaskEvent.t()} | {:error, Ecto.Changeset.t()}
  def record_event(%Task{} = task, kind, content)
      when is_atom(kind) and is_binary(content) do
    case task
         |> TaskEvent.changeset(Atom.to_string(kind), content, DateTime.utc_now())
         |> Repo.insert() do
      {:ok, event} ->
        Phoenix.PubSub.broadcast(
          AgentCodingBench.PubSub,
          "world",
          {:task_event, %{event | task: task}}
        )

        {:ok, event}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Returns the latest Task events, newest first, with their Tasks loaded."
  @spec recent_task_events(pos_integer()) :: [TaskEvent.t()]
  def recent_task_events(limit \\ 50) when is_integer(limit) and limit > 0 do
    Repo.all(
      from event in TaskEvent,
        order_by: [desc: event.at, desc: event.id],
        limit: ^limit,
        preload: :task
    )
  end

  @doc "Returns a Task transcript in occurrence order."
  @spec transcript(Task.t()) :: [TaskEvent.t()]
  def transcript(%Task{id: task_id}) do
    Repo.all(
      from event in TaskEvent,
        where: event.task_id == ^task_id,
        order_by: [asc: event.at, asc: event.id]
    )
  end

  @doc "Finalizes a running Task as merged."
  @spec finish_task(Task.t()) :: {:ok, Task.t()} | {:error, :not_running}
  def finish_task(%Task{} = task) do
    finalize_task(task, "merged", nil)
  end

  @doc "Finalizes a running Task with a mechanical abandonment reason."
  @spec abandon_task(Task.t(), atom()) :: {:ok, Task.t()} | {:error, term()}
  def abandon_task(%Task{} = task, reason) when is_atom(reason) do
    if reason in Task.abandon_reasons() do
      finalize_task(task, "abandoned", Atom.to_string(reason))
    else
      {:error, {:invalid_abandon_reason, reason}}
    end
  end

  @doc "Returns running Tasks for one Lane, or globally, in creation order."
  @spec running_tasks(non_neg_integer() | :all) :: [Task.t()]
  def running_tasks(lane \\ :all)
      when (is_integer(lane) and lane >= 0) or lane == :all do
    query =
      from task in Task,
        where: task.status == "running",
        order_by: [asc: task.id]

    query = if lane == :all, do: query, else: from(task in query, where: task.lane == ^lane)
    Repo.all(query)
  end

  @doc "Returns filtered Task history, newest first."
  @spec list_tasks(map()) :: [Task.t()]
  def list_tasks(filters \\ %{}) when is_map(filters) do
    Task
    |> filter_tasks_by_lane(Map.get(filters, "lane"))
    |> filter_tasks_by_repo(Map.get(filters, "world_repo"))
    |> filter_tasks_by_outcome(Map.get(filters, "outcome"))
    |> then(&from(task in &1, order_by: [desc: task.started_at, desc: task.id]))
    |> Repo.all()
  end

  @doc "Returns Task workload for the cohort started inside an observation window."
  @spec workload_for_window(DateTime.t(), DateTime.t()) :: %{
          task_ids: [pos_integer()],
          tasks_started: non_neg_integer(),
          merged: non_neg_integer(),
          abandoned: non_neg_integer(),
          review_cycles: non_neg_integer()
        }
  def workload_for_window(%DateTime{} = started_at, %DateTime{} = ended_at) do
    task_ids =
      Repo.all(
        from task in Task,
          where: task.started_at >= ^started_at and task.started_at <= ^ended_at,
          select: task.id
      )

    %{
      task_ids: task_ids,
      tasks_started: length(task_ids),
      merged: task_outcome_count(task_ids, "merged", started_at, ended_at),
      abandoned: task_outcome_count(task_ids, "abandoned", started_at, ended_at),
      review_cycles:
        Repo.one(
          from event in TaskEvent,
            where:
              event.task_id in ^task_ids and event.kind == "review" and
                event.at >= ^started_at and event.at <= ^ended_at,
            select: count(event.id)
        )
    }
  end

  @doc "Returns the Lane and World Repo values present in Task history."
  @spec task_filter_options() :: %{lanes: [non_neg_integer()], world_repos: [String.t()]}
  def task_filter_options do
    %{
      lanes: Repo.all(from task in Task, distinct: true, order_by: task.lane, select: task.lane),
      world_repos:
        Repo.all(
          from task in Task,
            distinct: true,
            order_by: task.world_repo,
            select: task.world_repo
        )
    }
  end

  @doc "Returns the ten latest Task titles for one Lane clone, oldest first."
  @spec recent_task_titles(non_neg_integer(), String.t()) :: [String.t()]
  def recent_task_titles(lane, world_repo)
      when is_integer(lane) and lane >= 0 and is_binary(world_repo) do
    Repo.all(
      from task in Task,
        where: task.lane == ^lane and task.world_repo == ^world_repo,
        order_by: [desc: task.id],
        limit: 10,
        select: task.title
    )
    |> Enum.reverse()
  end

  defp filter_tasks_by_lane(query, lane) when is_binary(lane) do
    case Integer.parse(lane) do
      {lane_number, ""} when lane_number >= 0 ->
        from task in query, where: task.lane == ^lane_number

      _invalid ->
        query
    end
  end

  defp filter_tasks_by_lane(query, _lane), do: query

  defp filter_tasks_by_repo(query, world_repo) when world_repo not in [nil, ""] do
    from task in query, where: task.world_repo == ^world_repo
  end

  defp filter_tasks_by_repo(query, _world_repo), do: query

  defp filter_tasks_by_outcome(query, outcome) when outcome in ~w(merged abandoned) do
    from task in query, where: task.status == ^outcome
  end

  defp filter_tasks_by_outcome(query, _outcome), do: query

  defp task_outcome_count(task_ids, status, started_at, ended_at) do
    Repo.one(
      from task in Task,
        where:
          task.id in ^task_ids and task.status == ^status and task.finished_at >= ^started_at and
            task.finished_at <= ^ended_at,
        select: count(task.id)
    )
  end

  defp broadcast_world_status(running?, lane_count) do
    Phoenix.PubSub.broadcast(
      AgentCodingBench.PubSub,
      "world",
      {:world_status, %{running?: running?, lane_count: lane_count}}
    )
  end

  defp finalize_task(task, status, reason) do
    query =
      from stored_task in Task,
        where: stored_task.id == ^task.id and stored_task.status == "running",
        select: stored_task

    case Repo.update_all(query,
           set: [status: status, abandon_reason: reason, finished_at: DateTime.utc_now()]
         ) do
      {1, [finished_task]} -> {:ok, finished_task}
      {0, []} -> {:error, :not_running}
    end
  end
end
