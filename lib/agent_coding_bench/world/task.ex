defmodule AgentCodingBench.World.Task do
  @moduledoc """
  One unit of work carried by a Lane from invention to merge or abandonment.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @abandon_reasons [
    :session_error,
    :inactivity_timeout,
    :task_timeout,
    :completion_failure,
    :lane_crash
  ]

  @sizes ~w(small medium large)

  @type t :: %__MODULE__{
          id: integer() | nil,
          lane: non_neg_integer() | nil,
          world_repo: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          persona_card: map() | nil,
          size: String.t() | nil,
          status: String.t() | nil,
          abandon_reason: String.t() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil
        }

  schema "tasks" do
    field :lane, :integer
    field :world_repo, :string
    field :title, :string
    field :description, :string
    field :persona_card, :map
    field :size, :string
    field :status, :string
    field :abandon_reason, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
  end

  @doc false
  def create_changeset(attrs, started_at) do
    %__MODULE__{
      lane: Map.get(attrs, :lane),
      world_repo: Map.get(attrs, :world_repo),
      title: Map.get(attrs, :title),
      description: Map.get(attrs, :description),
      persona_card: Map.get(attrs, :persona_card),
      size: Map.get(attrs, :size),
      status: "running",
      started_at: started_at
    }
    |> change()
    |> validate_required([
      :lane,
      :world_repo,
      :title,
      :description,
      :persona_card,
      :size,
      :status,
      :started_at
    ])
    |> validate_number(:lane, greater_than_or_equal_to: 0)
    |> validate_inclusion(:size, @sizes)
    |> validate_inclusion(:status, ~w(running merged abandoned))
  end

  @doc false
  def abandon_reasons, do: @abandon_reasons

  @doc false
  def sizes, do: @sizes
end
