defmodule AgentCodingBench.Stats.Call do
  @moduledoc """
  One client-observed unit of LLM work.
  """

  use Ecto.Schema
  import Ecto.Changeset

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

  @doc false
  def changeset(call) do
    call
    |> change()
    |> validate_required([
      :at,
      :lane,
      :role,
      :prompt_tokens,
      :completion_tokens,
      :reasoning_tokens,
      :cached_tokens,
      :duration_ms
    ])
    |> validate_inclusion(:role, ~w(pm reviewer person coder))
    |> validate_number(:lane, greater_than_or_equal_to: 0)
    |> validate_number(:prompt_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:completion_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:reasoning_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:cached_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:ttft_ms, greater_than_or_equal_to: 0)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:task_id)
  end
end
