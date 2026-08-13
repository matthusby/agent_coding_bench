defmodule AgentCodingBench.Repo.Migrations.CreateWorldTables do
  use Ecto.Migration

  def change do
    create table(:tasks) do
      add :lane, :integer, null: false
      add :world_repo, :text, null: false
      add :title, :text, null: false
      add :description, :text, null: false
      add :persona_card, :map, null: false
      add :status, :text, null: false
      add :abandon_reason, :text
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
    end

    create index(:tasks, [:lane, :world_repo, :started_at])
    create index(:tasks, [:status])

    create constraint(:tasks, :tasks_status_check,
             check: "status IN ('running', 'merged', 'abandoned')"
           )

    create constraint(:tasks, :tasks_outcome_check,
             check:
               "(status = 'running' AND finished_at IS NULL AND abandon_reason IS NULL) OR " <>
                 "(status = 'merged' AND finished_at IS NOT NULL AND abandon_reason IS NULL) OR " <>
                 "(status = 'abandoned' AND finished_at IS NOT NULL AND abandon_reason IS NOT NULL)"
           )

    create table(:task_events) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :kind, :text, null: false
      add :content, :text, null: false
      add :at, :utc_datetime_usec, null: false
    end

    create index(:task_events, [:task_id, :at])

    create constraint(:task_events, :task_events_kind_check,
             check: "kind IN ('question', 'answer', 'review', 'ruling', 'feedback')"
           )

    alter table(:calls) do
      modify :task_id, references(:tasks, on_delete: :nilify_all), from: :bigint
    end
  end
end
