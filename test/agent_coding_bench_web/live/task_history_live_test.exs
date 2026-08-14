defmodule AgentCodingBenchWeb.TaskHistoryLiveTest do
  use AgentCodingBenchWeb.ConnCase

  import Phoenix.LiveViewTest

  alias AgentCodingBench.World

  test "task history lists recorded Tasks", %{conn: conn} do
    {:ok, task} = create_task(3, "pydantic/pydantic", "Tighten schema errors")
    {:ok, task} = World.finish_task(task)

    {:ok, view, _html} = live(conn, ~p"/tasks")

    assert has_element?(view, "#task-history-page")

    assert has_element?(
             view,
             "#task-#{task.id}[data-lane='3'][data-repo='pydantic/pydantic'][data-outcome='merged']"
           )
  end

  test "filters Task history by lane, World Repo, and outcome", %{conn: conn} do
    {:ok, target} = create_task(2, "wojtekmach/req", "Target task")
    {:ok, target} = World.finish_task(target)

    {:ok, other_lane} = create_task(3, "wojtekmach/req", "Other lane")
    {:ok, other_lane} = World.finish_task(other_lane)

    {:ok, other_repo} = create_task(2, "pallets/flask", "Other repo")
    {:ok, other_repo} = World.finish_task(other_repo)

    {:ok, other_outcome} = create_task(2, "wojtekmach/req", "Other outcome")
    {:ok, other_outcome} = World.abandon_task(other_outcome, :task_timeout)

    {:ok, view, _html} = live(conn, ~p"/tasks")

    view
    |> form("#task-filters",
      filters: %{lane: "2", world_repo: "wojtekmach/req", outcome: "merged"}
    )
    |> render_change()

    assert has_element?(view, "#task-#{target.id}")
    refute has_element?(view, "#task-#{other_lane.id}")
    refute has_element?(view, "#task-#{other_repo.id}")
    refute has_element?(view, "#task-#{other_outcome.id}")
  end

  defp create_task(lane, world_repo, title) do
    World.create_task(%{
      lane: lane,
      world_repo: world_repo,
      title: title,
      description: "A focused task.",
      persona_card: %{"name" => "Rina"},
      size: "small"
    })
  end
end
