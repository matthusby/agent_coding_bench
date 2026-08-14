defmodule AgentCodingBench.WorldTest do
  use AgentCodingBench.DataCase, async: true

  alias AgentCodingBench.World
  alias AgentCodingBench.World.Task

  test "records a task, its transcript, and a merged outcome" do
    assert {:ok, task} =
             World.create_task(%{
               lane: 2,
               world_repo: "wojtekmach/req",
               title: "Expose retry diagnostics",
               description: "Make exhausted retries easier to diagnose.",
               persona_card: %{"name" => "Rina", "role" => "maintainer"},
               size: "small"
             })

    assert %Task{status: "running", finished_at: nil, abandon_reason: nil} = task
    assert %DateTime{} = task.started_at

    assert {:ok, question} = World.record_event(task, :question, "Should errors include URLs?")
    assert {:ok, answer} = World.record_event(task, :answer, "Yes, redact credentials.")

    assert World.transcript(task) == [question, answer]

    assert {:ok, merged} = World.finish_task(task)
    assert %Task{status: "merged", abandon_reason: nil} = merged
    assert %DateTime{} = merged.finished_at
  end

  test "mechanically abandons running tasks for one lane after a crash" do
    {:ok, swept} = create_task(4, "pallets/flask", "Swept task")
    {:ok, untouched} = create_task(5, "pydantic/pydantic", "Other lane")

    assert [running] = World.running_tasks(4)
    assert {:ok, abandoned} = World.abandon_task(running, :lane_crash)
    assert abandoned.id == swept.id
    assert abandoned.status == "abandoned"
    assert abandoned.abandon_reason == "lane_crash"
    assert %DateTime{} = abandoned.finished_at

    assert Repo.reload!(untouched).status == "running"
  end

  test "returns the ten most recent task titles for a lane and World Repo" do
    for number <- 1..12 do
      {:ok, _task} = create_task(1, "honojs/hono", "Task #{number}")
    end

    {:ok, _other_repo} = create_task(1, "wojtekmach/req", "Not included")
    {:ok, _other_lane} = create_task(2, "honojs/hono", "Also not included")

    assert World.recent_task_titles(1, "honojs/hono") ==
             Enum.map(3..12, &"Task #{&1}")
  end

  defp create_task(lane, world_repo, title) do
    World.create_task(%{
      lane: lane,
      world_repo: world_repo,
      title: title,
      description: "A self-contained task.",
      persona_card: %{"name" => "Rina"},
      size: "small"
    })
  end
end
