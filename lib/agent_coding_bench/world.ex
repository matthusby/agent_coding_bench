defmodule AgentCodingBench.World do
  @moduledoc """
  Task persistence and runtime control for the living agent-coding world.
  """

  import Ecto.Query, only: [from: 2]

  alias AgentCodingBench.Repo
  alias AgentCodingBench.World.Task
  alias AgentCodingBench.World.TaskEvent
  alias AgentCodingBench.World.LaneSupervisor
  alias AgentCodingBench.World.RuntimeSupervisor
  alias AgentCodingBench.World.Supervisor, as: WorldSupervisor

  @doc "Starts the World and its requested number of Lanes."
  @spec start(non_neg_integer()) :: {:ok, pid()} | {:error, term()}
  def start(lane_count) when is_integer(lane_count) and lane_count >= 0 do
    case DynamicSupervisor.start_child(RuntimeSupervisor, {WorldSupervisor, []}) do
      {:ok, pid} ->
        case LaneSupervisor.scale(lane_count) do
          :ok ->
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
      nil -> {:error, :not_started}
      pid -> DynamicSupervisor.terminate_child(RuntimeSupervisor, pid)
    end
  end

  @doc "Scales the running World without draining active Tasks."
  @spec scale_lanes(non_neg_integer()) :: :ok | {:error, :not_started | term()}
  def scale_lanes(lane_count) when is_integer(lane_count) and lane_count >= 0 do
    if Process.whereis(WorldSupervisor) do
      LaneSupervisor.scale(lane_count)
    else
      {:error, :not_started}
    end
  end

  @doc "Returns whether the ephemeral World supervisor is currently alive."
  @spec running?() :: boolean()
  def running?, do: Process.whereis(WorldSupervisor) != nil

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
    task
    |> TaskEvent.changeset(Atom.to_string(kind), content, DateTime.utc_now())
    |> Repo.insert()
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
