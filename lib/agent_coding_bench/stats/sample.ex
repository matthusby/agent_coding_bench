defmodule AgentCodingBench.Stats.Sample do
  @moduledoc """
  One raw vLLM metric value observed by the Collector.
  """

  use Ecto.Schema

  schema "samples" do
    field :scraped_at, :utc_datetime_usec
    field :metric, :string
    field :labels, :map, default: %{}
    field :value, :float
  end
end
