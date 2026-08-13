defmodule AgentCodingBench.World.CloneDigest do
  @moduledoc """
  Builds the bounded clone context handed to the PM.

  Git facts are read from the lane-local clone through the Box boundary. Task
  titles are supplied by the caller because task persistence belongs to the
  World context.
  """

  alias AgentCodingBench.Box

  @default_tree_depth 3
  @commit_count 20
  @task_title_count 10
  @ssh_opts [stderr_to_stdout: true]

  @doc "Captures and formats the PM's context digest for one clone."
  @spec capture(String.t(), [String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def capture(clone_path, task_titles, opts \\ [])
      when is_binary(clone_path) and is_list(task_titles) do
    exec = Keyword.get(opts, :exec, &Box.exec/2)
    tree_depth = Keyword.get(opts, :tree_depth, @default_tree_depth)
    quoted_path = shell_escape(clone_path)

    with {:ok, tree_output} <-
           run(exec, :tree, "git -C #{quoted_path} ls-tree -r --name-only HEAD"),
         paths = lines(tree_output),
         {:ok, readme} <- read_readme(exec, quoted_path, paths),
         {:ok, commit_log} <-
           run(
             exec,
             :commit_log,
             "git -C #{quoted_path} log -n #{@commit_count} --pretty=format:%h%x09%s"
           ) do
      {:ok,
       format(
         depth_cap(paths, tree_depth),
         readme,
         commit_log,
         Enum.take(task_titles, -@task_title_count)
       )}
    end
  end

  defp read_readme(exec, quoted_path, paths) do
    case Enum.find(paths, &readme?/1) do
      nil -> {:ok, "(no README found)"}
      path -> run(exec, :readme, "git -C #{quoted_path} show HEAD:#{shell_escape(path)}")
    end
  end

  defp readme?(path) do
    Path.dirname(path) == "." and
      path
      |> Path.basename()
      |> String.upcase()
      |> String.starts_with?("README")
  end

  defp depth_cap(paths, depth) when is_integer(depth) and depth > 0 do
    Enum.filter(paths, fn path -> length(Path.split(path)) <= depth end)
  end

  defp lines(output) do
    String.split(output, "\n", trim: true)
  end

  defp format(tree, readme, commit_log, task_titles) do
    """
    ## File tree
    #{Enum.join(tree, "\n")}

    ## README
    #{String.trim(readme)}

    ## Recent commits
    #{empty_marker(commit_log)}

    ## Recent tasks for this lane and clone
    #{task_titles |> Enum.map_join("\n", &"- #{&1}") |> empty_marker()}
    """
    |> String.trim()
  end

  defp empty_marker(value) do
    case String.trim(value) do
      "" -> "(none)"
      content -> content
    end
  end

  defp run(exec, fact, command) do
    case exec.(command, @ssh_opts) do
      {output, 0} when is_binary(output) -> {:ok, output}
      {output, status} -> {:error, {:clone_digest, fact, status, output}}
    end
  end

  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
