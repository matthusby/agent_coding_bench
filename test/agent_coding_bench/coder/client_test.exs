defmodule AgentCodingBench.Coder.ClientTest do
  use ExUnit.Case, async: true

  alias AgentCodingBench.Coder.Client

  test "delivers global SSE events from the request worker to the stream consumer" do
    runner = fn emit ->
      emit.("data: {\"directory\":\"/root/world/lanes/0/req\",")

      emit.(
        "\"payload\":{\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"session-44\"}}}\n\n"
      )

      :ok
    end

    assert {:ok, %{stream: stream}} =
             Client.request(%{
               method: :get,
               url: "/global/event",
               opts: [event_stream_runner: runner]
             })

    assert Enum.to_list(stream) == [
             %{
               "directory" => "/root/world/lanes/0/req",
               "payload" => %{
                 "type" => "session.idle",
                 "properties" => %{"sessionID" => "session-44"}
               }
             }
           ]
  end
end
