defmodule AgentCodingBench.World.LaneSupervisorTest do
  use ExUnit.Case, async: false

  alias AgentCodingBench.LaneFake
  alias AgentCodingBench.World.LaneSupervisor
  alias AgentCodingBench.World.SessionRegistry

  test "scales live Lanes up and down, removing the highest Lane numbers first" do
    supervisor =
      start_supervised!({LaneSupervisor, name: nil})

    scale_opts = [lane: LaneFake, lane_opts: [test_pid: self()], registry: SessionRegistry]

    assert :ok = LaneSupervisor.scale(supervisor, 3, scale_opts)
    assert_receive {:lane_started, 0, lane_0}
    assert_receive {:lane_started, 1, lane_1}
    assert_receive {:lane_started, 2, lane_2}
    assert LaneSupervisor.lanes(supervisor) == [0, 1, 2]

    lane_1_ref = Process.monitor(lane_1)
    lane_2_ref = Process.monitor(lane_2)
    assert :ok = LaneSupervisor.scale(supervisor, 1, scale_opts)
    assert_receive {:DOWN, ^lane_1_ref, :process, ^lane_1, :shutdown}
    assert_receive {:DOWN, ^lane_2_ref, :process, ^lane_2, :shutdown}
    assert [{^lane_0, _value}] = Registry.lookup(SessionRegistry, {:lane, 0})
    assert LaneSupervisor.lanes(supervisor) == [0]
  end
end
