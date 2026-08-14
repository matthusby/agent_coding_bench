defmodule AgentCodingBench.Stats.LiveSnapshot do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias AgentCodingBench.Repo
  alias AgentCodingBench.Stats.Call
  alias AgentCodingBench.Stats.Run
  alias AgentCodingBench.Stats.Sample
  alias AgentCodingBench.Stats.Serving
  alias AgentCodingBench.World
  alias AgentCodingBench.World.Task

  @window_seconds 15 * 60
  @call_rate_seconds 60
  @roles ~w(pm reviewer person coder)

  @spec build(keyword()) :: map()
  def build(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    world_running? = Keyword.get(opts, :world_running?, true)
    lane_statuses = Keyword.get_lazy(opts, :lane_statuses, &World.lane_statuses/0)
    latest_scrape_at = latest_scrape_at()
    window_end = window_end(now, latest_scrape_at, world_running?)
    window_start = DateTime.add(window_end, -@window_seconds, :second)

    %{
      generated_at: now,
      latest_scrape_at: latest_scrape_at,
      window: %{
        started_at: window_start,
        ended_at: window_end,
        seconds: @window_seconds
      },
      serving: Serving.for_window(window_start, window_end),
      world: world_activity(window_start, window_end, lane_statuses),
      active_run: active_run_summary(now)
    }
  end

  defp latest_scrape_at do
    Repo.one(from sample in Sample, select: max(sample.scraped_at))
  end

  defp window_end(now, _latest_scrape_at, true), do: now
  defp window_end(_now, %DateTime{} = latest_scrape_at, false), do: latest_scrape_at
  defp window_end(now, nil, false), do: now

  defp world_activity(started_at, ended_at, lane_statuses) do
    outcome_counts =
      Repo.all(
        from task in Task,
          where:
            task.status in ["merged", "abandoned"] and task.finished_at >= ^started_at and
              task.finished_at <= ^ended_at,
          group_by: task.status,
          select: {task.status, count(task.id)}
      )
      |> Map.new()

    role_counts =
      Repo.all(
        from call in Call,
          where: call.at >= ^started_at and call.at <= ^ended_at,
          group_by: call.role,
          select: {call.role, count(call.id)}
      )
      |> Map.new()

    calls_per_minute =
      Repo.one(
        from call in Call,
          where:
            call.at >= ^DateTime.add(ended_at, -@call_rate_seconds, :second) and
              call.at <= ^ended_at,
          select: count(call.id)
      )

    active_tasks =
      Repo.one(from task in Task, where: task.status == "running", select: count(task.id))

    %{
      lane_count: length(lane_statuses),
      busy_lanes: Enum.count(lane_statuses, &(not is_nil(Map.get(&1, :task_id)))),
      active_tasks: active_tasks,
      calls_per_minute: calls_per_minute,
      completed: Map.get(outcome_counts, "merged", 0),
      abandoned: Map.get(outcome_counts, "abandoned", 0),
      role_mix: Enum.map(@roles, &%{role: &1, count: Map.get(role_counts, &1, 0)})
    }
  end

  defp active_run_summary(now) do
    case active_run() do
      nil ->
        nil

      run ->
        task_counts = task_counts(run.started_at, now)

        calls =
          Repo.one(
            from call in Call,
              where: call.at >= ^run.started_at and call.at <= ^now,
              select: count(call.id)
          )

        %{
          id: run.id,
          name: run.name,
          notes: run.notes,
          lane_count: run.lane_count,
          started_at: run.started_at,
          elapsed_seconds: DateTime.diff(now, run.started_at),
          tasks_started: Enum.sum(Map.values(task_counts)),
          completed: Map.get(task_counts, "merged", 0),
          abandoned: Map.get(task_counts, "abandoned", 0),
          calls: calls
        }
    end
  end

  defp active_run do
    Repo.one(
      from run in Run,
        where: is_nil(run.ended_at),
        order_by: [desc: run.started_at],
        limit: 1
    )
  end

  defp task_counts(started_at, ended_at) do
    Repo.all(
      from task in Task,
        where: task.started_at >= ^started_at and task.started_at <= ^ended_at,
        group_by: task.status,
        select: {task.status, count(task.id)}
    )
    |> Map.new()
  end
end
