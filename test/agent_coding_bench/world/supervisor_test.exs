defmodule AgentCodingBench.World.SupervisorTest do
  use AgentCodingBench.DataCase, async: false

  alias AgentCodingBench.World
  alias AgentCodingBench.World.CrashSweep
  alias AgentCodingBench.World.CrashSweeper
  alias AgentCodingBench.World.Supervisor, as: WorldSupervisor
  alias AgentCodingBench.World.Task

  test "World start sweeps all running Tasks and resets their clones" do
    {:ok, task} =
      World.create_task(%{
        lane: 7,
        world_repo: "wojtekmach/req",
        title: "Interrupted task",
        description: "The app stopped mid-task.",
        persona_card: %{"name" => "Rina"}
      })

    test_pid = self()

    exec = fn command, _opts ->
      send(test_pid, {:reset_command, command})
      {"", 0}
    end

    supervisor =
      start_supervised!(
        {WorldSupervisor,
         name: nil,
         collector: false,
         event_relay: false,
         lane_supervisor: false,
         repos: [
           %{
             slug: "wojtekmach/req",
             clone_directory: "req",
             mirror_path: "/root/world/mirrors/req.git"
           }
         ],
         clone_root: "/root/world/lanes",
         exec: exec}
      )

    assert_receive {:reset_command, command}
    assert command =~ "/root/world/lanes/7/req"
    sweeper = child_pid(supervisor, CrashSweeper)
    assert :ok = CrashSweeper.await_ready(sweeper)

    assert %Task{status: "abandoned", abandon_reason: "lane_crash"} = Repo.reload!(task)
  end

  test "a failed clone reset leaves the Task running for the next crash sweep" do
    {:ok, task} =
      World.create_task(%{
        lane: 7,
        world_repo: "wojtekmach/req",
        title: "Still interrupted",
        description: "Recovery must be retryable.",
        persona_card: %{"name" => "Rina"}
      })

    repos = [
      %{
        slug: "wojtekmach/req",
        clone_directory: "req",
        mirror_path: "/root/world/mirrors/req.git"
      }
    ]

    exec = fn _command, _opts -> {"box unavailable", 255} end

    assert {:error, {:clone_operation, :reset, 255, "box unavailable"}} =
             CrashSweep.run(:all, repos, "/root/world/lanes", exec)

    assert %Task{status: "running", abandon_reason: nil} = Repo.reload!(task)
  end

  test "global crash recovery does not become ready before clone reset and persistence finish" do
    {:ok, task} =
      World.create_task(%{
        lane: 7,
        world_repo: "wojtekmach/req",
        title: "Ordered recovery",
        description: "Lanes must wait for this cleanup.",
        persona_card: %{"name" => "Rina"}
      })

    test_pid = self()

    exec = fn _command, _opts ->
      send(test_pid, {:reset_started, self()})

      receive do
        :finish_reset -> {"", 0}
      end
    end

    sweeper =
      start_supervised!(
        {CrashSweeper,
         name: nil,
         repos: [
           %{
             slug: "wojtekmach/req",
             clone_directory: "req",
             mirror_path: "/root/world/mirrors/req.git"
           }
         ],
         clone_root: "/root/world/lanes",
         exec: exec}
      )

    assert_receive {:reset_started, reset_worker}

    waiter =
      start_supervised!(
        {Elixir.Task,
         fn ->
           :ok = CrashSweeper.await_ready(sweeper)
           send(test_pid, :sweep_ready)
         end}
      )

    waiter_ref = Process.monitor(waiter)
    refute_receive :sweep_ready

    send(reset_worker, :finish_reset)
    assert_receive :sweep_ready
    assert_receive {:DOWN, ^waiter_ref, :process, ^waiter, :normal}
    assert %Task{status: "abandoned", abandon_reason: "lane_crash"} = Repo.reload!(task)
  end

  defp child_pid(supervisor, module) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {_id, pid, _type, [^module]} -> pid
      _child -> nil
    end)
  end
end
