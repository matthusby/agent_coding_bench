defmodule AgentCodingBench.World.CrashSweep do
  @moduledoc false

  alias AgentCodingBench.World
  alias AgentCodingBench.World.Clone

  @spec run(non_neg_integer() | :all, [map()], String.t(), function()) ::
          :ok | {:error, term()}
  def run(lane, repos, clone_root, exec) do
    repo_by_slug = Map.new(repos, &{&1.slug, &1})

    lane
    |> World.running_tasks()
    |> Enum.reduce_while(:ok, fn task, :ok ->
      case Map.fetch(repo_by_slug, task.world_repo) do
        {:ok, repo} ->
          path = Clone.path(task.lane, Map.get(repo, :clone_directory, repo.slug), clone_root)

          with :ok <- Clone.reset_if_present(path, exec: exec),
               {:ok, _task} <- World.abandon_task(task, :lane_crash) do
            {:cont, :ok}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end

        :error ->
          {:halt, {:error, {:unknown_world_repo, task.world_repo}}}
      end
    end)
  end
end
