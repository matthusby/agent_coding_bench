defmodule AgentCodingBenchWeb.LiveStatsLiveTest do
  use AgentCodingBenchWeb.ConnCase

  import Phoenix.LiveViewTest

  alias AgentCodingBench.Repo
  alias AgentCodingBench.Stats
  alias AgentCodingBench.Stats.Sample
  alias AgentCodingBench.WorldRuntimeFake

  setup do
    WorldRuntimeFake.reset()
    on_exit(&WorldRuntimeFake.reset/0)
  end

  test "shows the live serving and World dashboard", %{conn: conn} do
    {:ok, _pid} = WorldRuntimeFake.start(2)
    now = DateTime.utc_now()

    insert_sample(DateTime.add(now, -10, :second), "vllm:generation_tokens_total", 100)
    insert_sample(DateTime.add(now, -5, :second), "vllm:generation_tokens_total", 150)
    insert_sample(DateTime.add(now, -10, :second), "vllm:prompt_tokens_total", 100)
    insert_sample(DateTime.add(now, -5, :second), "vllm:prompt_tokens_total", 150)
    insert_sample(DateTime.add(now, -10, :second), "vllm:prompt_tokens_cached_total", 70)
    insert_sample(DateTime.add(now, -5, :second), "vllm:prompt_tokens_cached_total", 110)
    insert_sample(DateTime.add(now, -10, :second), "vllm:prefix_cache_hits_total", 50)
    insert_sample(DateTime.add(now, -5, :second), "vllm:prefix_cache_hits_total", 90)
    insert_sample(DateTime.add(now, -10, :second), "vllm:prefix_cache_queries_total", 100)
    insert_sample(DateTime.add(now, -5, :second), "vllm:prefix_cache_queries_total", 150)
    insert_sample(DateTime.add(now, -5, :second), "vllm:num_requests_running", 3)
    insert_sample(DateTime.add(now, -5, :second), "vllm:num_requests_waiting", 2)

    insert_sample(DateTime.add(now, -5, :second), "vllm:num_requests_waiting_by_reason", 2, %{
      "reason" => "capacity"
    })

    insert_sample(DateTime.add(now, -5, :second), "vllm:num_requests_waiting_by_reason", 1, %{
      "reason" => "deferred"
    })

    insert_sample(DateTime.add(now, -10, :second), "vllm:num_preemptions_total", 4)
    insert_sample(DateTime.add(now, -5, :second), "vllm:num_preemptions_total", 7)
    insert_sample(DateTime.add(now, -5, :second), "vllm:kv_cache_usage_perc", 0.42)

    {:ok, view, _html} = live(conn, "/stats/live")

    assert has_element?(view, "#live-stats-page")
    assert has_element?(view, "#stats-source[data-state='fresh']")
    assert has_element?(view, "#live-window[data-seconds='900']")
    assert has_element?(view, "#serving-section")
    assert has_element?(view, "#world-section")
    assert has_element?(view, "#serving-generation[data-value='10.0']")
    assert has_element?(view, "#serving-prompt[data-value='10.0']")
    assert has_element?(view, "#serving-cache[data-value='80.0'][data-prefix-hit='80.0']")
    assert has_element?(view, "#serving-prefill")

    assert has_element?(
             view,
             "#serving-requests[data-running='3.0'][data-waiting='2.0']"
           )

    assert has_element?(
             view,
             "#serving-queue-pressure[data-capacity='2.0'][data-deferred='1.0'][data-preemptions='3.0']"
           )

    assert has_element?(view, "#serving-kv-cache[data-value='42.0']")
    assert has_element?(view, "#live-active-run-empty")
  end

  test "refreshes after a Collector scrape broadcast", %{conn: conn} do
    {:ok, _pid} = WorldRuntimeFake.start(0)
    {:ok, view, _html} = live(conn, "/stats/live")

    assert has_element?(view, "#stats-source[data-state='awaiting']")
    refute has_element?(view, "#serving-kv-cache[data-value]")

    scraped_at = DateTime.utc_now()
    insert_sample(scraped_at, "vllm:kv_cache_usage_perc", 0.61)

    Phoenix.PubSub.broadcast(
      AgentCodingBench.PubSub,
      "stats",
      {:stats_scraped, %{scraped_at: scraped_at, sample_count: 1}}
    )

    assert has_element?(view, "#stats-source[data-state='fresh']")
    assert has_element?(view, "#serving-kv-cache[data-value='61.0']")
  end

  test "marks preserved data as stopped when the World is down", %{conn: conn} do
    insert_sample(
      DateTime.add(DateTime.utc_now(), -3_600, :second),
      "vllm:kv_cache_usage_perc",
      0.75
    )

    {:ok, view, _html} = live(conn, "/stats/live")

    assert has_element?(view, "#stats-source[data-state='stopped']")
    assert has_element?(view, "#stats-stale-notice")
    assert has_element?(view, "#serving-kv-cache[data-value='75.0']")
  end

  test "follows active Run changes", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/stats/live")
    assert has_element?(view, "#live-active-run-empty")

    assert {:ok, run} = Stats.start_run(%{name: "live load", lane_count: 4})

    assert has_element?(
             view,
             "#live-active-run[data-run-id='#{run.id}'][data-run-name='live load']"
           )

    assert {:ok, _run} = Stats.stop_run(run)
    assert has_element?(view, "#live-active-run-empty")
  end

  defp insert_sample(scraped_at, metric, value, labels \\ %{}) do
    Repo.insert!(%Sample{
      scraped_at: scraped_at,
      metric: metric,
      labels: labels,
      value: value / 1
    })
  end
end
