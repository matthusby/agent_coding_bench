defmodule AgentCodingBench.Repo.Migrations.AddTaskSize do
  use Ecto.Migration

  # Nullable on purpose: Tasks invented before the size rotation existed had no
  # bucket, and guessing one for them would corrupt the intended-vs-realized
  # comparison the column exists to support.
  def change do
    alter table(:tasks) do
      add :size, :text
    end

    create index(:tasks, [:size])
  end
end
