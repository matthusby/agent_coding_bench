defmodule AgentCodingBench.Stats.Collector do
  @moduledoc """
  Continuously scrapes raw vLLM metrics into the sample stream.

  The World supervisor owns this process; it will add the Collector to its
  child list when that supervisor lands in milestone 6.
  """

  use GenServer

  alias AgentCodingBench.Box
  alias AgentCodingBench.Repo
  alias AgentCodingBench.Stats.Metrics
  alias AgentCodingBench.Stats.Sample

  @default_interval 5_000

  @doc false
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      box: Keyword.get(opts, :box, Box),
      interval: Keyword.get(opts, :interval, @default_interval)
    }

    send(self(), :scrape)
    {:ok, state}
  end

  @impl true
  def handle_info(:scrape, state) do
    case collect(state) do
      {:ok, _count} ->
        Process.send_after(self(), :scrape, state.interval)
        {:noreply, state}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  defp collect(state) do
    scraped_at = DateTime.utc_now()

    with {:ok, exposition} <- state.box.scrape_metrics(),
         {:ok, samples} <- Metrics.parse(exposition, scraped_at) do
      {count, _rows} = Repo.insert_all(Sample, samples)

      Phoenix.PubSub.broadcast(
        AgentCodingBench.PubSub,
        "stats",
        {:stats_scraped, %{scraped_at: scraped_at, sample_count: count}}
      )

      {:ok, count}
    end
  end
end
