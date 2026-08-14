defmodule AgentCodingBench.World.Clone do
  @moduledoc """
  Git operations for one Lane-local World Repo clone.

  Every operation crosses the `AgentCodingBench.Box` boundary; the app never
  mounts or directly edits the remote clone filesystem.
  """

  alias AgentCodingBench.Box

  @ssh_opts [stderr_to_stdout: true]

  @doc "Returns the configured Lane-local path for a World Repo slug."
  @spec path(non_neg_integer(), String.t(), String.t()) :: String.t()
  def path(lane, slug, root \\ "/root/world/lanes")
      when is_integer(lane) and lane >= 0 and is_binary(slug) and is_binary(root) do
    Path.join([root, Integer.to_string(lane), slug])
  end

  @doc "Creates the clone when needed, cleans it to its drifting base, and cuts a Task branch."
  @spec prepare_task(String.t(), String.t(), integer(), keyword()) :: :ok | {:error, term()}
  def prepare_task(clone_path, mirror_path, task_id, opts \\ [])
      when is_binary(clone_path) and is_binary(mirror_path) and is_integer(task_id) do
    exec = Keyword.get(opts, :exec, &Box.exec/2)

    with :ok <- ensure_clone(exec, clone_path, mirror_path),
         :ok <- reset_with(exec, clone_path),
         :ok <-
           run(
             exec,
             :branch,
             "git -C #{shell_escape(clone_path)} switch -c #{shell_escape(branch(task_id))}"
           ) do
      :ok
    end
  end

  @doc "Creates a Lane clone from its box-local mirror when it does not exist."
  @spec ensure(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def ensure(clone_path, mirror_path, opts \\ [])
      when is_binary(clone_path) and is_binary(mirror_path) do
    ensure_clone(Keyword.get(opts, :exec, &Box.exec/2), clone_path, mirror_path)
  end

  @doc "Returns the complete branch diff, including untracked files as intent-to-add entries."
  @spec diff(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def diff(clone_path, opts \\ []) when is_binary(clone_path) do
    exec = Keyword.get(opts, :exec, &Box.exec/2)
    path = shell_escape(clone_path)

    command =
      base_assignment(path) <>
        " && git -C #{path} add -N . && git -C #{path} diff \"$base\""

    case exec.(command, @ssh_opts) do
      {output, 0} when is_binary(output) -> {:ok, output}
      {output, status} -> {:error, {:clone_operation, :diff, status, output}}
    end
  end

  @doc "Commits remaining work, merges the Task branch into the clone base, and deletes it."
  @spec merge(String.t(), integer(), String.t(), keyword()) :: :ok | {:error, term()}
  def merge(clone_path, task_id, title, opts \\ [])
      when is_binary(clone_path) and is_integer(task_id) and is_binary(title) do
    exec = Keyword.get(opts, :exec, &Box.exec/2)
    path = shell_escape(clone_path)
    branch = shell_escape(branch(task_id))
    message = shell_escape("bench task #{task_id}: #{title}")

    command =
      "git -C #{path} add -A" <>
        " && (git -C #{path} diff --cached --quiet || git -C #{path} commit -m #{message})" <>
        " && #{base_assignment(path)}" <>
        " && git -C #{path} switch \"$base\"" <>
        " && git -C #{path} merge --no-edit #{branch}" <>
        " && git -C #{path} branch -D #{branch}"

    run(exec, :merge, command)
  end

  @doc "Discards a Task branch and restores the clone's drifting base."
  @spec reset(String.t(), keyword()) :: :ok | {:error, term()}
  def reset(clone_path, opts \\ []) when is_binary(clone_path) do
    reset_with(Keyword.get(opts, :exec, &Box.exec/2), clone_path)
  end

  @doc """
  Resets the clone when it exists, and succeeds quietly when it does not.

  The box is disposable, so replacing it strands every running Task behind a Lane
  directory that no longer exists. Crash recovery still has to abandon those
  Tasks, and a bare `git -C` against a missing clone exits 128. Guarding inside
  the one remote command keeps a genuinely unreachable box distinguishable: that
  still fails, rather than looking like an absent clone.
  """
  @spec reset_if_present(String.t(), keyword()) :: :ok | {:error, term()}
  def reset_if_present(clone_path, opts \\ []) when is_binary(clone_path) do
    exec = Keyword.get(opts, :exec, &Box.exec/2)
    git_dir = shell_escape(Path.join(clone_path, ".git"))

    run(exec, :reset, "if [ -d #{git_dir} ]; then #{reset_command(clone_path)}; fi")
  end

  defp ensure_clone(exec, clone_path, mirror_path) do
    path = shell_escape(clone_path)
    git_dir = shell_escape(Path.join(clone_path, ".git"))
    parent = shell_escape(Path.dirname(clone_path))

    run(
      exec,
      :ensure,
      "if [ ! -d #{git_dir} ]; then mkdir -p #{parent} && git clone #{shell_escape(mirror_path)} #{path}; fi"
    )
  end

  defp reset_with(exec, clone_path) do
    run(exec, :reset, reset_command(clone_path))
  end

  defp reset_command(clone_path) do
    path = shell_escape(clone_path)

    # --discard-changes because the switch runs first: a plain `git switch`
    # refuses to leave a dirty tree, so a Coder killed mid-edit - which every
    # engine restart does - would abort the chain before `reset --hard` ever ran
    # and wedge the Lane for good. Discarding is the whole point of a reset.
    base_assignment(path) <>
      " && git -C #{path} switch --discard-changes \"$base\"" <>
      " && git -C #{path} reset --hard \"$base\"" <>
      " && git -C #{path} clean -fd" <>
      " && for branch in $(git -C #{path} for-each-ref --format='%(refname:short)' refs/heads); do " <>
      "[ \"$branch\" = \"$base\" ] || git -C #{path} branch -D \"$branch\"; done"
  end

  defp base_assignment(path) do
    "base_ref=$(git -C #{path} symbolic-ref --short refs/remotes/origin/HEAD)" <>
      " && base=${base_ref#origin/}"
  end

  defp branch(task_id), do: "bench-task-#{task_id}"

  defp run(exec, operation, command) do
    case exec.(command, @ssh_opts) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:clone_operation, operation, status, output}}
    end
  end

  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
