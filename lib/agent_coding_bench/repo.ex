defmodule AgentCodingBench.Repo do
  use Ecto.Repo,
    otp_app: :agent_coding_bench,
    adapter: Ecto.Adapters.Postgres
end
