defmodule AgentCodingBench.World.LaneTest do
  use AgentCodingBench.DataCase, async: false

  alias AgentCodingBench.CoderFake
  alias AgentCodingBench.LaneCastFake
  alias AgentCodingBench.World
  alias AgentCodingBench.World.Lane
  alias AgentCodingBench.World.Task

  test "carries one Task through rework in the same Coder session and then merges it" do
    lane = start_lane()

    reply_cast(
      Jason.encode!(%{
        title: "Expose retry diagnostics",
        description: "Make exhausted retries easier to diagnose."
      })
    )

    reply_cast(
      Jason.encode!(%{
        name: "Rina Patel",
        role: "maintainer",
        communication_style: "brief",
        pickiness: "actionable errors"
      })
    )

    assert_receive {:coder_request, :create_session, [%{}], create_worker, create_ref}
    send(create_worker, {:coder_reply, create_ref, {:ok, %{"id" => "session-44"}}})

    assert_receive {:coder_request, :prompt_async, ["session-44", opening_prompt], prompt_worker,
                    prompt_ref}

    assert opening_prompt =~ "exhausted retries"
    prompt_monitor = Process.monitor(prompt_worker)
    send(prompt_worker, {:coder_reply, prompt_ref, :ok})
    assert_receive {:DOWN, ^prompt_monitor, :process, ^prompt_worker, :normal}
    assert %{state: :coding, session_id: "session-44"} = Lane.status(lane)

    question = %{
      "type" => "question.asked",
      "properties" => %{
        "sessionID" => "session-44",
        "id" => "question-1",
        "questions" => [%{"question" => "Should URLs be included?"}]
      }
    }

    send(lane, {:coder_event, question})
    reply_cast("Yes, with credentials redacted.")

    assert_receive {:coder_request, :reply_question,
                    ["question-1", [["Yes, with credentials redacted."]]], question_worker,
                    question_ref}

    send(question_worker, {:coder_reply, question_ref, {:ok, true}})

    send(lane, {:coder_event, idle_event("session-44")})
    reply_cast("The URL is still missing from the exhausted-retry error.")
    reply_cast(Jason.encode!(%{decision: "rework", feedback: "Add the URL."}))

    assert_receive {:coder_request, :prompt_async, ["session-44", "Add the URL."], rework_worker,
                    rework_ref}

    rework_monitor = Process.monitor(rework_worker)
    send(rework_worker, {:coder_reply, rework_ref, :ok})
    assert_receive {:DOWN, ^rework_monitor, :process, ^rework_worker, :normal}
    assert %{state: :coding, session_id: "session-44"} = Lane.status(lane)

    send(lane, {:coder_event, idle_event("session-44")})
    reply_cast("The retry error now includes a safely redacted URL.")
    reply_cast(Jason.encode!(%{decision: "merge", feedback: "Looks good."}))

    assert_receive {:cast_request, _messages, %{role: :pm}, _lane, _ref}, 1_000

    task = Repo.one!(Task)
    assert task.status == "merged"
    assert task.finished_at

    assert Enum.map(World.transcript(task), &{&1.kind, &1.content}) == [
             {"question", "Should URLs be included?"},
             {"answer", "Yes, with credentials redacted."},
             {"review", "The URL is still missing from the exhausted-retry error."},
             {"ruling", "rework"},
             {"feedback", "Add the URL."},
             {"review", "The retry error now includes a safely redacted URL."},
             {"ruling", "merge"}
           ]
  end

  test "a Coder session error mechanically abandons the Task and starts fresh" do
    lane = start_coding_task()

    send(lane, {
      :coder_event,
      %{
        "type" => "session.error",
        "properties" => %{"sessionID" => "session-44", "error" => "tool loop failed"}
      }
    })

    assert_receive {:coder_request, :abort_session, ["session-44"], ^lane, abort_ref}
    send(lane, {:coder_reply, abort_ref, {:ok, true}})
    assert_receive {:cast_request, _messages, %{role: :pm}, _lane, _ref}, 1_000

    task = Repo.one!(Task)
    assert task.status == "abandoned"
    assert task.abandon_reason == "session_error"
  end

  test "an inactive Coder session is mechanically abandoned" do
    lane = start_coding_task(inactivity_timeout: 25)

    assert_receive {:coder_request, :abort_session, ["session-44"], ^lane, abort_ref}, 1_000
    send(lane, {:coder_reply, abort_ref, {:ok, true}})
    assert_receive {:cast_request, _messages, %{role: :pm}, _lane, _ref}, 1_000

    task = Repo.one!(Task)
    assert task.status == "abandoned"
    assert task.abandon_reason == "inactivity_timeout"
  end

  test "the per-Task hard cap spans the active Coder session" do
    lane = start_coding_task(task_timeout: 25)

    assert_receive {:coder_request, :abort_session, ["session-44"], ^lane, abort_ref}, 1_000
    send(lane, {:coder_reply, abort_ref, {:ok, true}})
    assert_receive {:cast_request, _messages, %{role: :pm}, _lane, _ref}, 1_000

    task = Repo.one!(Task)
    assert task.status == "abandoned"
    assert task.abandon_reason == "task_timeout"
  end

  test "the hard cap interrupts a stalled Reviewer completion" do
    lane = start_coding_task(task_timeout: 100)

    send(lane, {:coder_event, idle_event("session-44")})
    assert_receive {:cast_request, _messages, %{role: :reviewer}, _worker, _cast_ref}

    assert_receive {:coder_request, :abort_session, ["session-44"], ^lane, abort_ref}, 1_000
    send(lane, {:coder_reply, abort_ref, {:ok, true}})
    assert_receive {:cast_request, _messages, %{role: :pm}, _worker, _ref}, 1_000

    assert %Task{status: "abandoned", abandon_reason: "task_timeout"} = Repo.one!(Task)
  end

  test "the hard cap interrupts stalled Coder session creation" do
    lane = start_lane(task_timeout: 100)

    reply_cast(
      Jason.encode!(%{
        title: "Expose retry diagnostics",
        description: "Make exhausted retries easier to diagnose."
      })
    )

    reply_cast(
      Jason.encode!(%{
        name: "Rina Patel",
        role: "maintainer",
        communication_style: "brief",
        pickiness: "actionable errors"
      })
    )

    assert_receive {:coder_request, :create_session, [%{}], create_worker, _create_ref}
    create_monitor = Process.monitor(create_worker)

    assert_receive {:DOWN, ^create_monitor, :process, ^create_worker, :killed}, 1_000
    assert_receive {:cast_request, _messages, %{role: :pm}, _worker, _ref}, 1_000

    assert %Task{status: "abandoned", abandon_reason: "task_timeout"} = Repo.one!(Task)
    assert %{state: :inventing} = Lane.status(lane)
  end

  test "a failed Reviewer completion mechanically abandons the Task" do
    lane = start_coding_task()

    send(lane, {:coder_event, idle_event("session-44")})
    assert_receive {:cast_request, _messages, %{role: :reviewer}, review_worker, cast_ref}
    send(review_worker, {:cast_reply, cast_ref, {:error, :completion_http}})

    assert_receive {:coder_request, :abort_session, ["session-44"], ^lane, abort_ref}
    send(lane, {:coder_reply, abort_ref, {:ok, true}})
    assert_receive {:cast_request, _messages, %{role: :pm}, _lane, _ref}, 1_000

    assert %Task{status: "abandoned", abandon_reason: "completion_failure"} = Repo.one!(Task)
  end

  test "a failed PM completion retries invention without creating an abandoned Task" do
    _lane = start_lane(invention_retry_delay: 0)

    assert_receive {:cast_request, _messages, %{role: :pm}, cast_worker, cast_ref}
    send(cast_worker, {:cast_reply, cast_ref, {:error, :completion_http}})

    assert_receive {:cast_request, _messages, %{role: :pm}, _retry_worker, _retry_ref}, 1_000
    assert Repo.aggregate(Task, :count) == 0
  end

  test "an unexpected PM worker exit retries invention without crashing the Lane" do
    lane = start_lane(invention_retry_delay: 0)

    assert_receive {:cast_request, _messages, %{role: :pm}, cast_worker, _cast_ref}
    Process.exit(cast_worker, :completion_process_crashed)

    assert_receive {:cast_request, _messages, %{role: :pm}, _retry_worker, _retry_ref}, 1_000
    assert %{state: :inventing, task_id: nil} = Lane.status(lane)
  end

  test "the hard cap interrupts stalled PM invention before a Task row exists" do
    _lane = start_lane(task_timeout: 100, invention_retry_delay: 0)

    assert_receive {:cast_request, _messages, %{role: :pm}, cast_worker, _cast_ref}
    cast_monitor = Process.monitor(cast_worker)

    assert_receive {:DOWN, ^cast_monitor, :process, ^cast_worker, :killed}, 1_000
    assert_receive {:cast_request, _messages, %{role: :pm}, _retry_worker, _retry_ref}, 1_000
    assert Repo.aggregate(Task, :count) == 0
  end

  test "permission events count as activity without granting an undocumented policy" do
    lane = start_coding_task()

    send(lane, {
      :coder_event,
      %{
        "type" => "permission.asked",
        "properties" => %{"sessionID" => "session-44", "id" => "permission-1"}
      }
    })

    _ = :sys.get_state(lane)
    refute_receive {:coder_request, :reply_permission, _args, _worker, _ref}
    assert %{state: :coding} = Lane.status(lane)
  end

  test "Lane init sweeps a running Task left by its prior crashed process" do
    {:ok, crashed_task} =
      World.create_task(%{
        lane: 2,
        world_repo: "req",
        title: "Interrupted task",
        description: "This process died mid-task.",
        persona_card: %{"name" => "Rina"}
      })

    _lane = start_lane()
    assert_receive {:cast_request, _messages, %{role: :pm}, _lane, _ref}

    assert %Task{status: "abandoned", abandon_reason: "lane_crash"} =
             Repo.reload!(crashed_task)
  end

  test "failed global recovery retries the barrier instead of entering invention" do
    lane = start_lane(crash_sweeper: :missing_crash_sweeper, invention_retry_delay: 0)

    _ = :sys.get_state(lane)
    refute_receive {:cast_request, _messages, %{role: :pm}, _worker, _ref}
    assert %{state: :inventing, task_id: nil} = Lane.status(lane)
  end

  defp start_lane(opts \\ []) do
    test_pid = self()

    exec = fn command, _opts ->
      output =
        cond do
          String.contains?(command, "ls-tree") -> "README.md\nlib/req.ex\n"
          String.contains?(command, " show ") -> "# Req"
          String.contains?(command, " log ") -> "abc123\tInitial"
          String.contains?(command, " diff ") -> "diff --git a/lib/req.ex b/lib/req.ex"
          true -> ""
        end

      {output, 0}
    end

    defaults = [
      lane: 2,
      repos: [%{slug: "req", mirror_path: "/root/world/mirrors/req.git"}],
      clone_root: "/root/world/lanes",
      cast: LaneCastFake,
      cast_opts: [test_pid: test_pid],
      coder: CoderFake,
      coder_client: test_pid,
      exec: exec,
      crash_sweeper: false,
      inactivity_timeout: 60_000,
      task_timeout: 60_000,
      invention_retry_delay: 60_000,
      name: nil
    ]

    start_supervised!({Lane, Keyword.merge(defaults, opts)})
  end

  defp start_coding_task(opts \\ []) do
    lane = start_lane(opts)

    reply_cast(
      Jason.encode!(%{
        title: "Expose retry diagnostics",
        description: "Make exhausted retries easier to diagnose."
      })
    )

    reply_cast(
      Jason.encode!(%{
        name: "Rina Patel",
        role: "maintainer",
        communication_style: "brief",
        pickiness: "actionable errors"
      })
    )

    assert_receive {:coder_request, :create_session, [%{}], create_worker, create_ref}
    send(create_worker, {:coder_reply, create_ref, {:ok, %{"id" => "session-44"}}})

    assert_receive {:coder_request, :prompt_async, ["session-44", _prompt], prompt_worker,
                    prompt_ref}

    prompt_monitor = Process.monitor(prompt_worker)
    send(prompt_worker, {:coder_reply, prompt_ref, :ok})
    assert_receive {:DOWN, ^prompt_monitor, :process, ^prompt_worker, :normal}
    assert %{state: :coding} = Lane.status(lane)
    lane
  end

  defp reply_cast(content) do
    assert_receive {:cast_request, _messages, _context, lane, ref}
    send(lane, {:cast_reply, ref, {:ok, content}})
  end

  defp idle_event(session_id) do
    %{"type" => "session.idle", "properties" => %{"sessionID" => session_id}}
  end
end
