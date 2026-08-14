defmodule AgentCodingBench.CoderTest do
  use ExUnit.Case, async: true

  alias AgentCodingBench.Coder
  alias AgentCodingBench.OpenCodeClientFake

  test "normalizes the generated client's successful async prompt response" do
    client = [client: OpenCodeClientFake, test_pid: self(), response: {:ok, ""}]

    assert :ok = Coder.prompt_async(client, "session-44", "Fix the issue.")

    assert_receive {:opencode_request,
                    %{
                      method: :post,
                      url: "/session/session-44/prompt_async",
                      body: %{parts: [%{type: "text", text: "Fix the issue."}]}
                    }}
  end

  test "subscribes to global events and unwraps their instance payloads" do
    event = %{
      "type" => "question.asked",
      "properties" => %{"sessionID" => "session-44"}
    }

    client = [
      client: OpenCodeClientFake,
      test_pid: self(),
      response:
        {:ok, %{stream: [%{"directory" => "/root/world/lanes/0/req", "payload" => event}]}}
    ]

    assert {:ok, stream} = Coder.event_stream(client)
    assert Enum.to_list(stream) == [event]
    assert_receive {:opencode_request, %{method: :get, url: "/global/event"}}
  end
end
