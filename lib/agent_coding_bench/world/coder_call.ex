defmodule AgentCodingBench.World.CoderCall do
  @moduledoc """
  Decodes an opencode `message.updated` event into one recordable Coder Call.

  A Coder Call is a whole tool-loop turn, so the unit is the assistant message
  rather than the individual completions inside it - opencode reports usage only
  at that granularity. Turns are re-emitted as they stream and can be emitted
  again after finishing, so only messages carrying `time.completed` decode, and
  callers dedupe on the returned `id`.
  """

  @doc "Returns the Call fields for a finished assistant turn, or `:ignore`."
  @spec from_event(map()) ::
          {:ok,
           %{
             id: String.t(),
             prompt_tokens: non_neg_integer(),
             completion_tokens: non_neg_integer(),
             reasoning_tokens: non_neg_integer(),
             cached_tokens: non_neg_integer(),
             duration_ms: non_neg_integer()
           }}
          | :ignore
  def from_event(%{"info" => info}) when is_map(info), do: decode(info)
  def from_event(_properties), do: :ignore

  defp decode(
         %{
           "role" => "assistant",
           "id" => id,
           "time" => %{"created" => created, "completed" => completed}
         } = info
       )
       when is_binary(id) and is_integer(created) and is_integer(completed) do
    tokens = Map.get(info, "tokens") || %{}
    cache = Map.get(tokens, "cache") || %{}

    {:ok,
     %{
       id: id,
       prompt_tokens: count(tokens, "input"),
       completion_tokens: count(tokens, "output"),
       reasoning_tokens: count(tokens, "reasoning"),
       cached_tokens: count(cache, "read"),
       duration_ms: max(completed - created, 0)
     }}
  end

  defp decode(_info), do: :ignore

  # opencode types these as numbers rather than integers, and omits them on a
  # turn that failed before the provider answered.
  defp count(map, key) do
    case Map.get(map, key) do
      value when is_number(value) and value > 0 -> trunc(value)
      _ -> 0
    end
  end
end
