defmodule AgentCodingBench.StatsTest do
  use AgentCodingBench.DataCase, async: true

  alias AgentCodingBench.Stats
  alias AgentCodingBench.Stats.Run
  alias AgentCodingBench.BoxFake

  test "start_run captures the lane count and initial serving fingerprint" do
    BoxFake.put_fingerprint(%{"model" => "deepseek-v4"}, "digest-a")

    assert {:ok, run} =
             Stats.start_run(
               %{name: "baseline", notes: "idle", lane_count: 0, tags: ["idle"]},
               box: BoxFake
             )

    assert %Run{
             name: "baseline",
             notes: "idle",
             lane_count: 0,
             tags: ["idle"],
             fingerprint: %{"model" => "deepseek-v4"},
             fingerprint_digest: "digest-a",
             fingerprint_mismatch: false,
             ended_at: nil
           } = run

    assert %DateTime{} = run.started_at
  end

  test "start_run rejects a second active Run" do
    BoxFake.put_fingerprint(%{"model" => "deepseek-v4"}, "digest-a")
    assert {:ok, _run} = Stats.start_run(%{name: "first", lane_count: 0}, box: BoxFake)

    assert {:error, changeset} =
             Stats.start_run(%{name: "second", lane_count: 2}, box: BoxFake)

    assert "another Run is already active" in errors_on(changeset).ended_at
  end

  test "stop_run captures a new fingerprint and flags a changed digest" do
    BoxFake.put_fingerprint(%{"model" => "deepseek-v4"}, "digest-a")
    {:ok, run} = Stats.start_run(%{name: "load", lane_count: 4}, box: BoxFake)

    BoxFake.put_fingerprint(%{"model" => "changed"}, "digest-b")

    assert {:ok, stopped_run} = Stats.stop_run(run, box: BoxFake)
    assert %DateTime{} = stopped_run.ended_at
    assert stopped_run.fingerprint_mismatch
    assert stopped_run.fingerprint == %{"model" => "deepseek-v4"}
    assert stopped_run.fingerprint_digest == "digest-a"
  end

  test "stop_run rejects a stale attempt to stop the same Run twice" do
    BoxFake.put_fingerprint(%{"model" => "deepseek-v4"}, "digest-a")
    {:ok, run} = Stats.start_run(%{name: "load", lane_count: 4}, box: BoxFake)
    stale_run = Repo.get!(Run, run.id)

    assert {:ok, stopped_run} = Stats.stop_run(run, box: BoxFake)
    assert {:error, changeset} = Stats.stop_run(stale_run, box: BoxFake)
    assert "run is already stopped" in errors_on(changeset).ended_at

    assert Repo.get!(Run, run.id).ended_at == stopped_run.ended_at
  end

  test "stop_run leaves the mismatch flag clear when the digest is unchanged" do
    BoxFake.put_fingerprint(%{"model" => "deepseek-v4"}, "digest-a")
    {:ok, run} = Stats.start_run(%{name: "load", lane_count: 4}, box: BoxFake)

    assert {:ok, stopped_run} = Stats.stop_run(run, box: BoxFake)
    refute stopped_run.fingerprint_mismatch
  end
end
