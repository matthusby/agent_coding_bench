defmodule AgentCodingBenchWeb.WorldLiveTest do
  use AgentCodingBenchWeb.ConnCase

  import Phoenix.LiveViewTest

  alias AgentCodingBench.World
  alias AgentCodingBench.World.SessionRegistry

  setup do
    AgentCodingBench.WorldRuntimeFake.reset()
    on_exit(&AgentCodingBench.WorldRuntimeFake.reset/0)
  end

  test "world page shows the world shell and Run controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#world-page")
    assert has_element?(view, "#world-status[data-state=down]")
    assert has_element?(view, "#world-form")
    assert has_element?(view, "#world-form input[name='world[lane_count]'][min='0'][value='0']")
    assert has_element?(view, "#world-start:not([disabled])")
    assert has_element?(view, "#world-stop[disabled]")
    assert has_element?(view, "#run-form")
    assert has_element?(view, "#run-form input[name='run[name]']")
    assert has_element?(view, "#run-form textarea[name='run[notes]']")
    assert has_element?(view, "#run-start")
    assert has_element?(view, "#live-stats-link[href='/stats/live']")
  end

  test "starts and stops an idle World", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#world-form", world: %{lane_count: "0"})
    |> render_submit()

    assert has_element?(view, "#world-status[data-state=up]")
    assert has_element?(view, "#world-scale")
    assert has_element?(view, "#world-stop:not([disabled])")

    view |> element("#world-stop") |> render_click()

    assert has_element?(view, "#world-status[data-state=down]")
    assert has_element?(view, "#world-start")
    assert has_element?(view, "#world-stop[disabled]")
  end

  test "lane grid follows Lane status broadcasts", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    Phoenix.PubSub.broadcast(
      AgentCodingBench.PubSub,
      "world",
      {:lane_status,
       %{
         lane: 2,
         state: :coding,
         task_id: 42,
         task_title: "Expose retry diagnostics",
         world_repo: "wojtekmach/req",
         session_id: "session-42",
         state_started_at: DateTime.add(DateTime.utc_now(), -75, :second),
         last_event_at: DateTime.add(DateTime.utc_now(), -5, :second),
         last_abandon_reason: nil
       }}
    )

    assert has_element?(
             view,
             "#lane-2[data-state='coding'][data-task-id='42'][data-repo='wojtekmach/req']"
           )

    assert has_element?(view, "#lane-2 [data-role='task-title']")
    assert has_element?(view, "#lane-2 [data-role='time-in-state']")
    assert has_element?(view, "#lane-2 [data-role='last-event-age']")

    Phoenix.PubSub.broadcast(AgentCodingBench.PubSub, "world", {:lane_removed, 2})

    refute has_element?(view, "#lane-2")
  end

  test "lane grid includes Lanes that were running before mount", %{conn: conn} do
    status = %{
      lane: 7,
      state: :reviewing,
      task_id: 77,
      task_title: "Review an existing task",
      world_repo: "honojs/hono",
      session_id: "session-77",
      state_started_at: DateTime.utc_now(),
      last_event_at: DateTime.utc_now(),
      last_abandon_reason: nil
    }

    start_supervised!(
      {AgentCodingBench.LaneFake,
       name: {:via, Registry, {SessionRegistry, {:lane, 7}}},
       lane: 7,
       status: status,
       test_pid: self()}
    )

    assert_receive {:lane_started, 7, _pid}

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             "#lane-7[data-state='reviewing'][data-task-id='77'][data-repo='honojs/hono']"
           )
  end

  test "event tail shows recent events and follows new records", %{conn: conn} do
    {:ok, task} = create_task(1, "pallets/flask", "Clarify route errors")
    {:ok, question} = World.record_event(task, :question, "Which routes should change?")

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             "#task-event-#{question.id}[data-kind='question'][data-task-id='#{task.id}']"
           )

    {:ok, answer} = World.record_event(task, :answer, "Only routes under the API scope.")

    assert has_element?(
             view,
             "#task-event-#{answer.id}[data-kind='answer'][data-task-id='#{task.id}']"
           )
  end

  test "starts a Run with the configured lane count", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#run-form",
      run: %{name: "idle baseline", notes: "manual traffic only"}
    )
    |> render_submit()

    assert has_element?(view, "#active-run[data-lane-count='0']")
    assert has_element?(view, "#active-run[data-run-name='idle baseline']")
    assert has_element?(view, "#run-stop")
    refute has_element?(view, "#run-start")

    {:ok, remounted_view, _html} = live(build_conn(), ~p"/")
    assert has_element?(remounted_view, "#active-run[data-run-name='idle baseline']")
  end

  test "stops the active Run", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#run-form", run: %{name: "load", notes: ""})
    |> render_submit()

    view |> element("#run-stop") |> render_click()

    refute has_element?(view, "#active-run")
    assert has_element?(view, "#run-start")

    {:ok, remounted_view, _html} = live(build_conn(), ~p"/")
    refute has_element?(remounted_view, "#active-run")
    assert has_element?(remounted_view, "#run-start")
  end

  test "a stale dashboard refreshes to a Run started elsewhere", %{conn: conn} do
    {:ok, first_view, _html} = live(conn, ~p"/")
    {:ok, stale_view, _html} = live(build_conn(), ~p"/")

    first_view
    |> form("#run-form", run: %{name: "first", notes: ""})
    |> render_submit()

    stale_view
    |> form("#run-form", run: %{name: "second", notes: ""})
    |> render_submit()

    assert has_element?(stale_view, "#active-run[data-run-name='first']")
    assert has_element?(stale_view, "#run-stop")
    refute has_element?(stale_view, "#run-start")
  end

  test "a stale dashboard refreshes after the Run is stopped elsewhere", %{conn: conn} do
    {:ok, first_view, _html} = live(conn, ~p"/")

    first_view
    |> form("#run-form", run: %{name: "shared", notes: ""})
    |> render_submit()

    {:ok, stale_view, _html} = live(build_conn(), ~p"/")
    first_view |> element("#run-stop") |> render_click()
    stale_view |> element("#run-stop") |> render_click()

    refute has_element?(stale_view, "#active-run")
    assert has_element?(stale_view, "#run-start")
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
