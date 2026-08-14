defmodule AgentCodingBench.World.CloneTest do
  use ExUnit.Case, async: true

  alias AgentCodingBench.World.Clone

  test "prepares a clean task branch in an on-demand lane clone" do
    test_pid = self()

    exec = fn command, opts ->
      send(test_pid, {:exec, command, opts})
      {"", 0}
    end

    assert :ok =
             Clone.prepare_task(
               "/root/world/lanes/2/req",
               "/root/world/mirrors/req.git",
               44,
               exec: exec
             )

    assert_received {:exec, ensure_command, [stderr_to_stdout: true]}
    assert ensure_command =~ "git clone '/root/world/mirrors/req.git' '/root/world/lanes/2/req'"

    assert_received {:exec, reset_command, [stderr_to_stdout: true]}
    # The switch has to discard: it runs before `reset --hard`, and a Coder
    # killed mid-edit leaves changes a plain `git switch` refuses to overwrite.
    assert reset_command =~ "git -C '/root/world/lanes/2/req' switch --discard-changes"
    assert reset_command =~ " reset --hard"
    assert reset_command =~ " clean -fd"

    assert_received {:exec, branch_command, [stderr_to_stdout: true]}
    assert branch_command =~ "switch -c 'bench-task-44'"
  end

  test "captures all branch changes and merges approved work into the clone base" do
    test_pid = self()

    exec = fn command, _opts ->
      send(test_pid, {:exec, command})

      if String.contains?(command, " diff "),
        do: {"diff --git a/lib/a.ex b/lib/a.ex", 0},
        else: {"", 0}
    end

    assert {:ok, diff} = Clone.diff("/root/world/lanes/2/req", exec: exec)
    assert diff =~ "diff --git"
    assert_received {:exec, diff_command}
    assert diff_command =~ " add -N ."
    assert diff_command =~ " diff"

    assert :ok =
             Clone.merge("/root/world/lanes/2/req", 44, "Fix retry's output", exec: exec)

    assert_received {:exec, merge_command}
    assert merge_command =~ " add -A"
    assert merge_command =~ " commit"
    assert merge_command =~ " merge --no-edit 'bench-task-44'"
    assert merge_command =~ " branch -D 'bench-task-44'"
    assert merge_command =~ "Fix retry'\"'\"'s output"
  end

  test "reports failed git operations through the Box boundary" do
    exec = fn _command, _opts -> {"fatal: broken clone", 128} end

    assert {:error, {:clone_operation, :ensure, 128, "fatal: broken clone"}} =
             Clone.prepare_task("/clone", "/mirror.git", 1, exec: exec)
  end
end
