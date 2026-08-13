defmodule AgentCodingBench.Stats.Call do
  @moduledoc """
  One client-observed unit of LLM work.
  """

  use Ecto.Schema

  schema "calls" do
    field :at, :utc_datetime_usec
    field :lane, :integer
    field :role, :string
    field :task_id, :integer
    field :prompt_tokens, :integer
    field :completion_tokens, :integer
    field :reasoning_tokens, :integer
    field :cached_tokens, :integer
    field :ttft_ms, :integer
    field :duration_ms, :integer
  end
end
