defmodule AgentCodingBench.Repo.Migrations.EnsureOneActiveRun do
  use Ecto.Migration

  def change do
    create unique_index(:runs, ["(true)"],
             where: "ended_at IS NULL",
             name: :runs_one_active_index
           )
  end
end
