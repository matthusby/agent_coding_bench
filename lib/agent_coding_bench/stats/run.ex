defmodule AgentCodingBench.Stats.Run do
  @moduledoc """
  A named observation window over the continuously collected sample stream.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "runs" do
    field :name, :string
    field :notes, :string
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :lane_count, :integer
    field :fingerprint, :map
    field :fingerprint_digest, :string
    field :fingerprint_mismatch, :boolean, default: false
    field :tags, {:array, :string}, default: []
  end

  @doc false
  def start_changeset(run, attrs, capture, started_at) do
    run
    |> cast(attrs, [:name, :notes, :lane_count, :tags])
    |> validate_required([:name, :lane_count])
    |> validate_number(:lane_count, greater_than_or_equal_to: 0)
    |> put_change(:started_at, started_at)
    |> put_change(:fingerprint, capture.fingerprint)
    |> put_change(:fingerprint_digest, capture.digest)
  end

  @doc false
  def stop_changeset(run, capture, ended_at) do
    change(run,
      ended_at: ended_at,
      fingerprint_mismatch: run.fingerprint_digest != capture.digest
    )
  end
end
