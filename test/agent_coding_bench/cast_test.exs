defmodule AgentCodingBench.CastTest do
  use AgentCodingBench.DataCase, async: true

  alias AgentCodingBench.Cast
  alias AgentCodingBench.Stats.Call

  test "complete returns streamed prose and records client-observed usage" do
    request = fn opts ->
      assert opts[:url] == "http://vllm.test/v1/chat/completions"
      assert opts[:json]["stream"]
      assert opts[:json]["stream_options"] == %{"include_usage" => true}

      chunks = [
        ~s(data: {"choices":[{"delta":{"content":"Review"}}]}\n\n),
        ~s(data: {"choices":[{"delta":{"content":" complete"}}]}\n\n),
        ~s(data: {"choices":[],"usage":{"prompt_tokens":21,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":8},"completion_tokens_details":{"reasoning_tokens":2}}}\n\n),
        "data: [DONE]\n\n"
      ]

      response = stream_response(Keyword.fetch!(opts, :into), chunks)
      {:ok, response}
    end

    assert {:ok, "Review complete"} =
             Cast.complete(
               [%{role: "user", content: "Review this diff"}],
               %{lane: 4, role: :reviewer, task_id: 91},
               request: request,
               model: "test-model",
               vllm_url: "http://vllm.test"
             )

    assert %Call{
             lane: 4,
             role: "reviewer",
             task_id: 91,
             prompt_tokens: 21,
             completion_tokens: 5,
             reasoning_tokens: 2,
             cached_tokens: 8,
             ttft_ms: ttft_ms,
             duration_ms: duration_ms
           } = Repo.one!(Call)

    assert ttft_ms >= 0
    assert duration_ms >= ttft_ms
  end

  test "records an observed completion even when the model returns no prose" do
    request = fn opts ->
      chunks = [
        ~s(data: {"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":0}}\n\n),
        "data: [DONE]\n\n"
      ]

      {:ok, stream_response(Keyword.fetch!(opts, :into), chunks)}
    end

    assert {:error, :empty_completion} =
             Cast.complete(
               [%{role: "user", content: "Review this diff"}],
               %{lane: 4, role: :reviewer, task_id: 91},
               request: request,
               model: "test-model",
               vllm_url: "http://vllm.test"
             )

    assert %Call{prompt_tokens: 7, completion_tokens: 0, ttft_ms: nil} = Repo.one!(Call)
  end

  defp stream_response(into, chunks) do
    {_request, response} =
      Enum.reduce(chunks, {Req.Request.new(), Req.Response.new(status: 200)}, fn chunk, acc ->
        assert {:cont, next_acc} = into.({:data, chunk}, acc)
        next_acc
      end)

    response
  end
end
