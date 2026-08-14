defmodule AgentCodingBenchWeb.RunCompareLiveTest do
  use AgentCodingBenchWeb.ConnCase

  import Phoenix.LiveViewTest

  alias AgentCodingBench.Repo
  alias AgentCodingBench.Stats.Run
  alias AgentCodingBench.Stats.Sample

  test "shows an empty state until two Runs are available", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/runs/compare")

    assert has_element?(view, "#run-compare-page")
    assert has_element?(view, "#run-compare-empty")
    refute has_element?(view, "#run-ledger")
  end

  test "defaults to the newest two Runs and renders the real-data ledger", %{conn: conn} do
    run_a = insert_run("baseline-8", ~U[2026-08-13 12:00:00.000000Z], 20, 8, "same")
    run_b = insert_run("push-16", ~U[2026-08-13 13:00:00.000000Z], 10, 16, "same")
    insert_counter(run_a, [100, 150, 210])
    insert_counter(run_b, [400, 480])

    {:ok, view, _html} = live(conn, ~p"/runs/compare")

    assert has_element?(view, "#run-ledger")

    assert has_element?(
             view,
             "#run-chip-a[data-run-id='#{run_a.id}'][data-duration-seconds='20']"
           )

    assert has_element?(
             view,
             "#run-chip-b[data-run-id='#{run_b.id}'][data-duration-seconds='10']"
           )

    assert has_element?(view, "#config-match[data-match='true']")
    assert has_element?(view, "#metric-row-generation_throughput")
    assert has_element?(view, "#metric-row-ttft")
    assert has_element?(view, "#metric-row-itl")
    assert has_element?(view, "#metric-row-requests")
    assert has_element?(view, "#metric-row-kv_cache")
    assert has_element?(view, "#spark-generation_throughput-a[data-last-offset='20']")
    assert has_element?(view, "#spark-generation_throughput-b[data-last-offset='10']")
    assert has_element?(view, "#workload-row-tasks_started")
    refute has_element?(view, "#calls-by-role")
  end

  test "selects a different Run pair through URL-backed controls", %{conn: conn} do
    oldest = insert_run("oldest", ~U[2026-08-13 11:00:00.000000Z], 10, 4, "old")
    middle = insert_run("middle", ~U[2026-08-13 12:00:00.000000Z], 10, 8, "new")
    newest = insert_run("newest", ~U[2026-08-13 13:00:00.000000Z], 10, 16, "new")

    {:ok, view, _html} = live(conn, ~p"/runs/compare")

    view
    |> form("#run-compare-form", compare: %{run_a: oldest.id, run_b: middle.id})
    |> render_submit()

    assert_patch(view, ~p"/runs/compare?#{%{run_a: oldest.id, run_b: middle.id}}")
    assert has_element?(view, "#run-chip-a[data-run-id='#{oldest.id}']")
    assert has_element?(view, "#run-chip-b[data-run-id='#{middle.id}']")
    assert has_element?(view, "#config-match[data-match='false']")
    refute has_element?(view, "#run-chip-b[data-run-id='#{newest.id}']")
  end

  defp insert_run(name, started_at, duration_seconds, lane_count, digest) do
    Repo.insert!(%Run{
      name: name,
      started_at: started_at,
      ended_at: DateTime.add(started_at, duration_seconds, :second),
      lane_count: lane_count,
      fingerprint: %{"model" => "deepseek-v4"},
      fingerprint_digest: digest,
      fingerprint_mismatch: false,
      tags: []
    })
  end

  defp insert_counter(run, values) do
    values
    |> Enum.with_index()
    |> Enum.each(fn {value, index} ->
      Repo.insert!(%Sample{
        scraped_at: DateTime.add(run.started_at, index * 10, :second),
        metric: "vllm:generation_tokens_total",
        labels: %{},
        value: value / 1
      })
    end)
  end
end
