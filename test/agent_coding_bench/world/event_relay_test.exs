defmodule AgentCodingBench.World.EventRelayTest do
  use ExUnit.Case, async: true

  alias AgentCodingBench.CoderFake
  alias AgentCodingBench.World.EventRelay
  alias AgentCodingBench.World.SessionRegistry

  test "routes a coder event to the lane registered for its session" do
    session_id = "session-#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.register(SessionRegistry, session_id, nil)

    _relay =
      start_supervised!(
        {EventRelay, name: nil, coder: CoderFake, client: self(), reconnect_delay: 0}
      )

    assert_receive {:event_stream_subscribed, stream}

    event = %{
      "type" => "session.idle",
      "properties" => %{"sessionID" => session_id}
    }

    send(stream, {:event, event})

    assert_receive {:coder_event, ^event}
  end

  test "reconnects and routes pending questions and permissions after stream failure" do
    session_id = "session-#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.register(SessionRegistry, session_id, nil)

    _relay =
      start_supervised!(
        {EventRelay, name: nil, coder: CoderFake, client: self(), reconnect_delay: 0}
      )

    assert_receive {:event_stream_subscribed, first_stream}
    send(first_stream, {:fail, :closed})

    assert_receive {:event_stream_subscribed, second_stream}
    refute first_stream == second_stream
    refute_receive {:coder_request, :pending_questions, [], _relay, _ref}

    send(second_stream, {:event, %{"type" => "server.connected", "properties" => %{}}})

    assert_receive {:coder_request, :pending_questions, [], relay, questions_ref}

    question = %{"id" => "question-1", "sessionID" => session_id, "questions" => []}
    send(relay, {:coder_reply, questions_ref, {:ok, [question]}})

    assert_receive {:coder_request, :pending_permissions, [], ^relay, permissions_ref}

    permission = %{"id" => "permission-1", "sessionID" => session_id}
    send(relay, {:coder_reply, permissions_ref, {:ok, [permission]}})

    assert_receive {:coder_event, %{"type" => "question.asked", "properties" => ^question}}

    assert_receive {:coder_event, %{"type" => "permission.asked", "properties" => ^permission}}
  end
end
