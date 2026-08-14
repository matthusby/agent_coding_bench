defmodule AgentCodingBench.StatsTest do
  use AgentCodingBench.DataCase, async: true

  alias AgentCodingBench.Stats
  alias AgentCodingBench.Stats.Call
  alias AgentCodingBench.Stats.Run
  alias AgentCodingBench.Stats.Sample
  alias AgentCodingBench.BoxFake
  alias AgentCodingBench.World
  alias AgentCodingBench.World.Task

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

  test "Run changes are broadcast to live stats subscribers" do
    Phoenix.PubSub.subscribe(AgentCodingBench.PubSub, "stats")
    BoxFake.put_fingerprint(%{"model" => "deepseek-v4"}, "digest-a")

    assert {:ok, run} = Stats.start_run(%{name: "live", lane_count: 2}, box: BoxFake)
    assert_receive {:run_status, %{active?: true, run_id: run_id}}
    assert run_id == run.id

    assert {:ok, _stopped_run} = Stats.stop_run(run, box: BoxFake)
    assert_receive {:run_status, %{active?: false, run_id: ^run_id}}
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

  test "live_snapshot combines rolling serving and World activity with active Run totals" do
    now = ~U[2026-08-13 12:15:00.000000Z]
    run_started_at = DateTime.add(now, -600, :second)

    Repo.insert!(%Run{
      name: "live load",
      started_at: run_started_at,
      lane_count: 2,
      fingerprint: %{"model" => "deepseek-v4"},
      fingerprint_digest: "same",
      tags: []
    })

    insert_sample(DateTime.add(now, -10, :second), "vllm:generation_tokens_total", 100)
    insert_sample(DateTime.add(now, -5, :second), "vllm:generation_tokens_total", 150)
    insert_sample(DateTime.add(now, -10, :second), "vllm:prompt_tokens_total", 1_000)
    insert_sample(DateTime.add(now, -5, :second), "vllm:prompt_tokens_total", 1_500)
    insert_sample(DateTime.add(now, -10, :second), "vllm:prompt_tokens_cached_total", 800)
    insert_sample(DateTime.add(now, -5, :second), "vllm:prompt_tokens_cached_total", 1_250)
    insert_sample(DateTime.add(now, -10, :second), "vllm:prefix_cache_hits_total", 700)
    insert_sample(DateTime.add(now, -5, :second), "vllm:prefix_cache_hits_total", 1_100)
    insert_sample(DateTime.add(now, -10, :second), "vllm:prefix_cache_queries_total", 1_000)
    insert_sample(DateTime.add(now, -5, :second), "vllm:prefix_cache_queries_total", 1_500)
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
    insert_sample(DateTime.add(now, -1_000, :second), "vllm:kv_cache_usage_perc", 0.99)

    insert_snapshot_histogram(
      now,
      "vllm:request_prefill_time_seconds_bucket",
      [0, 0, 0, 0, 0],
      [1, 5, 9, 10, 10]
    )

    active = insert_snapshot_task("running", DateTime.add(now, -500, :second), nil)

    merged =
      insert_snapshot_task(
        "merged",
        DateTime.add(now, -450, :second),
        DateTime.add(now, -300, :second)
      )

    _abandoned =
      insert_snapshot_task(
        "abandoned",
        DateTime.add(now, -400, :second),
        DateTime.add(now, -200, :second)
      )

    insert_snapshot_call("coder", active.id, DateTime.add(now, -30, :second))
    insert_snapshot_call("pm", merged.id, DateTime.add(now, -120, :second))
    insert_snapshot_call("reviewer", merged.id, DateTime.add(now, -1_000, :second))

    snapshot =
      Stats.live_snapshot(
        now: now,
        world_running?: true,
        lane_statuses: [%{task_id: active.id}, %{task_id: nil}]
      )

    assert snapshot.latest_scrape_at == DateTime.add(now, -5, :second)
    assert [%{offset_seconds: 895, value: 10.0}] = snapshot.serving.generation
    assert [%{offset_seconds: 895, value: 100.0}] = snapshot.serving.prompt
    assert [%{offset_seconds: 895, value: 90.0}] = snapshot.serving.prompt_cache_hit
    assert [%{offset_seconds: 895, value: 80.0}] = snapshot.serving.prefix_cache_hit
    assert [%{offset_seconds: 895, value: 0.5}] = snapshot.serving.prefill_p50
    assert [%{offset_seconds: 895, value: prefill_p99}] = snapshot.serving.prefill_p99
    assert_in_delta prefill_p99, 1.9, 0.0001
    assert List.last(snapshot.serving.running).value == 3.0
    assert List.last(snapshot.serving.waiting).value == 2.0
    assert List.last(snapshot.serving.waiting_capacity).value == 2.0
    assert List.last(snapshot.serving.waiting_deferred).value == 1.0
    assert List.last(snapshot.serving.preemptions).value == 3.0
    assert List.last(snapshot.serving.kv_cache).value == 42.0

    assert snapshot.world == %{
             active_tasks: 1,
             abandoned: 1,
             busy_lanes: 1,
             calls_per_minute: 1,
             completed: 1,
             lane_count: 2,
             role_mix: [
               %{count: 1, role: "pm"},
               %{count: 0, role: "reviewer"},
               %{count: 0, role: "person"},
               %{count: 1, role: "coder"}
             ]
           }

    assert snapshot.active_run.name == "live load"
    assert snapshot.active_run.elapsed_seconds == 600
    assert snapshot.active_run.tasks_started == 3
    assert snapshot.active_run.completed == 1
    assert snapshot.active_run.abandoned == 1
    assert snapshot.active_run.calls == 2
  end

  test "a stopped live snapshot preserves the final fifteen-minute window" do
    last_scrape_at = ~U[2026-08-13 12:00:00.000000Z]
    now = DateTime.add(last_scrape_at, 3_600, :second)

    insert_sample(last_scrape_at, "vllm:kv_cache_usage_perc", 0.75)

    snapshot =
      Stats.live_snapshot(
        now: now,
        world_running?: false,
        lane_statuses: []
      )

    assert snapshot.window.ended_at == last_scrape_at
    assert snapshot.window.started_at == DateTime.add(last_scrape_at, -900, :second)
    assert [%{offset_seconds: 900, value: 75.0}] = snapshot.serving.kv_cache
  end

  test "compare_runs aligns serving gauges and counter rates by offset from each Run start" do
    run_a = insert_run("baseline-8", ~U[2026-08-13 12:00:00.000000Z], 30, 8, "same")
    run_b = insert_run("push-16", ~U[2026-08-13 13:00:00.000000Z], 20, 16, "same")

    insert_series(run_a, "vllm:generation_tokens_total", [100, 150, 210])
    insert_series(run_b, "vllm:generation_tokens_total", [400, 480, 580])
    insert_series(run_a, "vllm:num_requests_running", [2, 4, 3])
    insert_series(run_b, "vllm:num_requests_running", [7, 8, 9])
    insert_series(run_a, "vllm:num_requests_waiting", [0, 1, 2])
    insert_series(run_b, "vllm:num_requests_waiting", [1, 4, 3])
    insert_series(run_a, "vllm:kv_cache_usage_perc", [0.25, 0.5, 0.75])
    insert_series(run_b, "vllm:kv_cache_usage_perc", [0.4, 0.6, 0.8])

    comparison = Stats.compare_runs!(run_a.id, run_b.id)

    assert comparison.config_match?
    assert comparison.max_duration_seconds == 30

    throughput = metric_row(comparison, :generation_throughput)

    assert throughput.a.lines.generation == [
             %{offset_seconds: 10, value: 5.0},
             %{offset_seconds: 20, value: 6.0}
           ]

    assert throughput.b.lines.generation == [
             %{offset_seconds: 10, value: 8.0},
             %{offset_seconds: 20, value: 10.0}
           ]

    assert throughput.a.summary == 5.5
    assert throughput.b.summary == 9.0

    requests = metric_row(comparison, :requests)
    assert requests.a.lines.running == offset_series([2, 4, 3])
    assert requests.b.lines.waiting == offset_series([1, 4, 3])
    assert requests.a.summary == 2.0
    assert requests.b.summary == 4.0

    kv_cache = metric_row(comparison, :kv_cache)
    assert kv_cache.a.lines.usage == offset_series([25.0, 50.0, 75.0])
    assert kv_cache.b.summary == 80.0
  end

  test "compare_runs derives latency percentiles from histogram bucket increases" do
    run_a = insert_run("baseline", ~U[2026-08-13 12:00:00.000000Z], 30, 8, "a")
    run_b = insert_run("candidate", ~U[2026-08-13 13:00:00.000000Z], 20, 8, "b")

    insert_histogram(run_a, "vllm:time_to_first_token_seconds_bucket", [
      [0, 0, 0, 0, 0],
      [1, 5, 9, 10, 10],
      [3, 13, 19, 20, 20],
      [3, 13, 19, 20, 20]
    ])

    insert_histogram(run_b, "vllm:time_to_first_token_seconds_bucket", [
      [0, 0, 0, 0, 0],
      [2, 8, 10, 10, 10]
    ])

    insert_histogram(
      run_a,
      "vllm:inter_token_latency_seconds_bucket",
      [[0, 0, 0, 0, 0], [1, 5, 9, 10, 10]],
      ["0.01", "0.05", "0.1", "0.2", "+Inf"]
    )

    comparison = Stats.compare_runs!(run_a.id, run_b.id)

    ttft = metric_row(comparison, :ttft)

    assert [%{offset_seconds: 10, value: 0.5}, %{offset_seconds: 20, value: p50}] =
             ttft.a.lines.p50

    assert_in_delta p50, 0.3, 0.0001

    assert [%{offset_seconds: 10, value: p99_a}, %{offset_seconds: 20, value: p99_b}] =
             ttft.a.lines.p99

    assert_in_delta p99_a, 1.9, 0.0001
    assert_in_delta p99_b, 0.975, 0.0001
    assert_in_delta ttft.a.summary, 1.4375, 0.0001

    itl = metric_row(comparison, :itl)
    assert [%{offset_seconds: 10, value: 50.0}] = itl.a.lines.p50
    assert [%{offset_seconds: 10, value: itl_p99}] = itl.a.lines.p99
    assert_in_delta itl_p99, 190.0, 0.0001
  end

  test "compare_runs excludes the first tenth of samples from headline summaries" do
    run_a = insert_run("warmup", ~U[2026-08-13 12:00:00.000000Z], 90, 8, "a")
    run_b = insert_run("steady", ~U[2026-08-13 13:00:00.000000Z], 90, 8, "b")

    insert_series(run_a, "vllm:kv_cache_usage_perc", [1.0 | List.duplicate(0.5, 9)])
    insert_series(run_b, "vllm:kv_cache_usage_perc", List.duplicate(0.4, 10))

    comparison = Stats.compare_runs!(run_a.id, run_b.id)

    assert metric_row(comparison, :kv_cache).a.summary == 50.0
  end

  test "compare_runs includes workload activity observed inside each Run window" do
    started_at = DateTime.add(DateTime.utc_now(), -1_800, :second)
    run_a = insert_run("workload", started_at, 3_600, 2, "a")
    run_b = insert_run("idle", DateTime.add(started_at, 7_200, :second), 3_600, 0, "b")

    {:ok, merged} = create_task(1, "Merged task")
    {:ok, abandoned} = create_task(2, "Abandoned task")
    {:ok, _merged} = World.finish_task(merged)
    {:ok, _abandoned} = World.abandon_task(abandoned, :task_timeout)

    for _cycle <- 1..3 do
      {:ok, _event} = World.record_event(merged, :review, "Review notes")
    end

    for _turn <- 1..5 do
      assert {:ok, _call} = record_coder_call(merged.id)
    end

    preexisting =
      Repo.insert!(%Task{
        lane: 1,
        world_repo: "wojtekmach/req",
        title: "Pre-existing Task",
        description: "Started before the Run.",
        persona_card: %{"name" => "Rina"},
        status: "running",
        started_at: DateTime.add(started_at, -10, :second)
      })

    {:ok, _event} = World.record_event(preexisting, :review, "Outside the Run-start cohort")
    {:ok, _call} = record_coder_call(preexisting.id)

    comparison = Stats.compare_runs!(run_a.id, run_b.id)

    assert workload_row(comparison, :tasks_started) == %{
             key: :tasks_started,
             label: "Tasks started",
             a: 2,
             b: 0
           }

    assert workload_row(comparison, :merged).a == 1
    assert workload_row(comparison, :abandoned).a == 1
    assert workload_row(comparison, :tasks_per_hour).a == 2.0
    assert workload_row(comparison, :review_cycles_per_task).a == 1.5
    assert workload_row(comparison, :coder_turns_per_task).a == 2.5
    assert workload_row(comparison, :coder_turns_per_task).b == nil
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

  defp insert_sample(scraped_at, metric, value, labels \\ %{}) do
    Repo.insert!(%Sample{
      scraped_at: scraped_at,
      metric: metric,
      labels: labels,
      value: value / 1
    })
  end

  defp insert_snapshot_task(status, started_at, finished_at) do
    Repo.insert!(%Task{
      lane: 1,
      world_repo: "wojtekmach/req",
      title: "Snapshot task",
      description: "A focused task.",
      persona_card: %{"name" => "Rina"},
      status: status,
      abandon_reason: if(status == "abandoned", do: "task_timeout"),
      started_at: started_at,
      finished_at: finished_at
    })
  end

  defp insert_snapshot_call(role, task_id, at) do
    Repo.insert!(%Call{
      at: at,
      lane: 1,
      role: role,
      task_id: task_id,
      prompt_tokens: 100,
      completion_tokens: 20,
      reasoning_tokens: 5,
      cached_tokens: 10,
      duration_ms: 1_000
    })
  end

  defp insert_snapshot_histogram(now, metric, previous_counts, current_counts) do
    bounds = ["0.1", "0.5", "1", "2", "+Inf"]

    for {at, counts} <- [
          {DateTime.add(now, -10, :second), previous_counts},
          {DateTime.add(now, -5, :second), current_counts}
        ],
        {bound, count} <- Enum.zip(bounds, counts) do
      insert_sample(at, metric, count, %{"le" => bound, "model_name" => "deepseek-v4"})
    end
  end

  defp insert_series(run, metric, values) do
    values
    |> Enum.with_index()
    |> Enum.each(fn {value, index} ->
      Repo.insert!(%Sample{
        scraped_at: DateTime.add(run.started_at, index * 10, :second),
        metric: metric,
        labels: %{},
        value: value / 1
      })
    end)
  end

  defp insert_histogram(run, metric, snapshots, bounds \\ ["0.1", "0.5", "1", "2", "+Inf"]) do
    snapshots
    |> Enum.with_index()
    |> Enum.each(fn {counts, index} ->
      Enum.zip(bounds, counts)
      |> Enum.each(fn {bound, count} ->
        Repo.insert!(%Sample{
          scraped_at: DateTime.add(run.started_at, index * 10, :second),
          metric: metric,
          labels: %{"le" => bound, "model_name" => "deepseek-v4"},
          value: count / 1
        })
      end)
    end)
  end

  defp metric_row(comparison, key), do: Enum.find(comparison.metrics, &(&1.key == key))
  defp workload_row(comparison, key), do: Enum.find(comparison.workload, &(&1.key == key))

  defp create_task(lane, title) do
    World.create_task(%{
      lane: lane,
      world_repo: "wojtekmach/req",
      title: title,
      description: "A focused task.",
      persona_card: %{"name" => "Rina"}
    })
  end

  defp record_coder_call(task_id) do
    Stats.record_call(%{
      at: DateTime.utc_now(),
      lane: 1,
      role: "coder",
      task_id: task_id,
      prompt_tokens: 100,
      completion_tokens: 20,
      reasoning_tokens: 5,
      cached_tokens: 10,
      ttft_ms: nil,
      duration_ms: 1_000
    })
  end

  defp offset_series(values) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {value, index} -> %{offset_seconds: index * 10, value: value / 1} end)
  end
end
