defmodule AgentCodingBench.World.CloneDigestTest do
  use ExUnit.Case, async: true

  alias AgentCodingBench.World.CloneDigest

  test "captures a depth-capped tree, README, recent commits, and the last ten task titles" do
    exec = fn command, _opts ->
      cond do
        String.contains?(command, "ls-tree") ->
          {".github/README.md\nREADME.md\nlib/a.ex\nlib/a/b.ex\nlib/a/b/c.ex\n", 0}

        String.contains?(command, " show ") ->
          assert String.ends_with?(command, "HEAD:'README.md'")
          {"# Example\n\nA small repository.\n", 0}

        String.contains?(command, " log ") ->
          {"abc123\tAdd parser\ndef456\tFix docs", 0}
      end
    end

    titles = ["old-one", "old-two"] ++ Enum.map(3..12, &"task-#{&1}")

    assert {:ok, digest} =
             CloneDigest.capture("/root/world/lanes/2/example", titles,
               exec: exec,
               tree_depth: 3
             )

    assert digest =~ "README.md\nlib/a.ex\nlib/a/b.ex"
    refute digest =~ "lib/a/b/c.ex"
    assert digest =~ "# Example"
    assert digest =~ "abc123\tAdd parser"
    refute digest =~ "old-one"
    assert digest =~ "task-3"
    assert digest =~ "task-12"
  end
end
