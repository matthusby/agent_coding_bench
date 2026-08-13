defmodule AgentCodingBench.CastFake do
  @moduledoc false

  @behaviour AgentCodingBench.Cast

  def put_completions(completions) when is_list(completions) do
    Process.put({__MODULE__, :completions}, completions)
  end

  @impl true
  def complete(messages, context, opts) do
    send(self(), {:cast_completion, messages, context, opts})

    case Process.get({__MODULE__, :completions}, []) do
      [completion | rest] ->
        Process.put({__MODULE__, :completions}, rest)
        completion

      [] ->
        {:error, :no_fake_completion}
    end
  end
end
