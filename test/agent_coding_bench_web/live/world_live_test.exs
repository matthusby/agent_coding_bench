defmodule AgentCodingBenchWeb.WorldLiveTest do
  use AgentCodingBenchWeb.ConnCase

  import Phoenix.LiveViewTest

  test "world page shows the world shell and Run controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#world-page")
    assert has_element?(view, "#world-status[data-state=down]")
    assert has_element?(view, "#world-start[disabled]")
    assert has_element?(view, "#world-stop[disabled]")
    assert has_element?(view, "#run-form")
    assert has_element?(view, "#run-form input[name='run[lane_count]'][min='0'][value='0']")
    assert has_element?(view, "#run-form input[name='run[name]']")
    assert has_element?(view, "#run-form textarea[name='run[notes]']")
    assert has_element?(view, "#run-start")
  end

  test "starts a Run with the configured lane count", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#run-form",
      run: %{lane_count: "0", name: "idle baseline", notes: "manual traffic only"}
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
    |> form("#run-form", run: %{lane_count: "3", name: "load", notes: ""})
    |> render_submit()

    assert has_element?(
             view,
             "#run-form input[name='run[lane_count]'][value='3'][disabled]"
           )

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
    |> form("#run-form", run: %{lane_count: "1", name: "first", notes: ""})
    |> render_submit()

    stale_view
    |> form("#run-form", run: %{lane_count: "2", name: "second", notes: ""})
    |> render_submit()

    assert has_element?(stale_view, "#active-run[data-run-name='first']")
    assert has_element?(stale_view, "#run-stop")
    refute has_element?(stale_view, "#run-start")
  end

  test "a stale dashboard refreshes after the Run is stopped elsewhere", %{conn: conn} do
    {:ok, first_view, _html} = live(conn, ~p"/")

    first_view
    |> form("#run-form", run: %{lane_count: "1", name: "shared", notes: ""})
    |> render_submit()

    {:ok, stale_view, _html} = live(build_conn(), ~p"/")
    first_view |> element("#run-stop") |> render_click()
    stale_view |> element("#run-stop") |> render_click()

    refute has_element?(stale_view, "#active-run")
    assert has_element?(stale_view, "#run-start")
  end
end
