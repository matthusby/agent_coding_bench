defmodule AgentCodingBench.World.CrashSweepTest do
  use AgentCodingBench.DataCase, async: true

  alias AgentCodingBench.World
  alias AgentCodingBench.World.CrashSweep

  @repos [
    %{
      slug: "supabase/realtime",
      clone_directory: "realtime",
      upstream_url: "https://github.com/supabase/realtime.git",
      mirror_path: "/root/world/mirrors/realtime.git"
    }
  ]

  @clone_root "/root/world/lanes"
  @clone_path "/root/world/lanes/3/realtime"

  test "abandons a running Task whose clone the box no longer has" do
    {:ok, task} = create_running_task()
    test_pid = self()

    # Stands in for a replaced box: the Lane directory is gone, so an unguarded
    # `git -C` exits 128 the way the real box does, while a command that checks
    # for the clone first simply does nothing and exits 0.
    exec = fn command, _opts ->
      send(test_pid, {:exec, command})

      if String.starts_with?(command, "if [ -d ") do
        {"", 0}
      else
        {"fatal: cannot change to '#{@clone_path}': No such file or directory\n", 128}
      end
    end

    assert :ok = CrashSweep.run(:all, @repos, @clone_root, exec)

    assert_received {:exec, command}
    assert command =~ "if [ -d '#{@clone_path}/.git' ]; then "
    # The guard must not have quietly neutered the reset itself.
    assert command =~ "git -C '#{@clone_path}' reset --hard"

    assert %{status: "abandoned", abandon_reason: "lane_crash"} = Repo.reload!(task)
  end

  defp create_running_task do
    World.create_task(%{
      lane: 3,
      world_repo: "supabase/realtime",
      title: "Fix the reconnect backoff",
      description: "Backoff resets too eagerly after a dropped socket.",
      persona_card: %{"name" => "bench"}
    })
  end
end
