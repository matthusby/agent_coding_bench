defmodule AgentCodingBench.Repo.Migrations.CreateStatsTables do
  use Ecto.Migration

  def change do
    create table(:samples) do
      add :scraped_at, :utc_datetime_usec, null: false
      add :metric, :text, null: false
      add :labels, :map, null: false, default: %{}
      add :value, :float, null: false
    end

    create index(:samples, [:scraped_at])
    create index(:samples, [:metric, :scraped_at])

    create table(:runs) do
      add :name, :text, null: false
      add :notes, :text
      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :lane_count, :integer, null: false
      add :fingerprint, :map, null: false
      add :fingerprint_digest, :text, null: false
      add :fingerprint_mismatch, :boolean, null: false, default: false
      add :tags, {:array, :text}, null: false, default: []
    end

    create index(:runs, [:started_at])

    create table(:calls) do
      add :at, :utc_datetime_usec, null: false
      add :lane, :integer, null: false
      add :role, :text, null: false
      # Milestone 6 adds the foreign key when it creates the tasks table.
      add :task_id, :bigint
      add :prompt_tokens, :integer, null: false
      add :completion_tokens, :integer, null: false
      add :reasoning_tokens, :integer, null: false
      add :cached_tokens, :integer, null: false
      add :ttft_ms, :integer
      add :duration_ms, :integer, null: false
    end

    create index(:calls, [:at])
    create index(:calls, [:task_id])
  end
end
