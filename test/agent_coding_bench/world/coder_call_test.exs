defmodule AgentCodingBench.World.CoderCallTest do
  use ExUnit.Case, async: true

  alias AgentCodingBench.World.CoderCall

  # Field names and shapes taken from opencode's own OpenAPI document
  # (`GET /doc`, schemas `EventMessageUpdated` and `AssistantMessage`).
  defp properties(overrides \\ %{}) do
    info =
      Map.merge(
        %{
          "id" => "msg_01",
          "role" => "assistant",
          "sessionID" => "ses_01",
          "time" => %{"created" => 1_000, "completed" => 4_500},
          "tokens" => %{
            "input" => 12_000,
            "output" => 300,
            "reasoning" => 40,
            "cache" => %{"read" => 9_000, "write" => 1_200}
          }
        },
        overrides
      )

    %{"sessionID" => "ses_01", "info" => info}
  end

  test "decodes a finished assistant turn" do
    assert {:ok, turn} = CoderCall.from_event(properties())

    assert turn == %{
             id: "msg_01",
             # opencode's `input` excludes cache reads, so the whole prompt is
             # 12_000 + 9_000. Every other role's `prompt_tokens` already counts
             # its cached tokens, and the column has to mean one thing.
             prompt_tokens: 21_000,
             completion_tokens: 300,
             reasoning_tokens: 40,
             cached_tokens: 9_000,
             duration_ms: 3_500
           }
  end

  test "ignores a turn still streaming" do
    # `time.completed` is optional in the schema and absent until the turn ends;
    # token counts are not final before then.
    assert :ignore = CoderCall.from_event(properties(%{"time" => %{"created" => 1_000}}))
  end

  test "ignores user messages and malformed events" do
    assert :ignore = CoderCall.from_event(properties(%{"role" => "user"}))
    assert :ignore = CoderCall.from_event(%{"sessionID" => "ses_01"})
    assert :ignore = CoderCall.from_event(%{"info" => "not-a-map"})
  end

  test "defaults missing usage to zero rather than dropping the turn" do
    assert {:ok, turn} = CoderCall.from_event(properties(%{"tokens" => %{"input" => 5}}))

    assert turn.prompt_tokens == 5
    assert turn.completion_tokens == 0
    assert turn.reasoning_tokens == 0
    assert turn.cached_tokens == 0
  end

  test "never reports a negative duration" do
    clock_skew = properties(%{"time" => %{"created" => 9_000, "completed" => 1_000}})

    assert {:ok, %{duration_ms: 0}} = CoderCall.from_event(clock_skew)
  end
end
