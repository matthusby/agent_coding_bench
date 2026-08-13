defmodule AgentCodingBench.LaneCastFake do
  @moduledoc false

  @behaviour AgentCodingBench.Cast

  @impl true
  def complete(messages, context, opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    ref = make_ref()
    send(test_pid, {:cast_request, messages, context, self(), ref})

    receive do
      {:cast_reply, ^ref, result} -> result
    end
  end
end
