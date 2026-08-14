defmodule AgentCodingBench.Stats.CollectorTest do
  use AgentCodingBench.DataCase, async: false

  import Ecto.Query

  alias AgentCodingBench.Repo
  alias AgentCodingBench.BoxFake
  alias AgentCodingBench.Stats.Collector
  alias AgentCodingBench.Stats.Sample

  test "collector scrapes on start and persists only raw vLLM samples" do
    Phoenix.PubSub.subscribe(AgentCodingBench.PubSub, "stats")

    collector =
      start_supervised!({Collector, name: nil, box: BoxFake, interval: 60_000})

    _ = :sys.get_state(collector)

    assert [sample] = Repo.all(from sample in Sample, select: sample)
    assert sample.metric == "vllm:num_requests_running"
    assert sample.labels == %{"engine" => "0"}
    assert sample.value == 3.0
    assert %DateTime{} = sample.scraped_at

    assert_receive {:stats_scraped, %{scraped_at: scraped_at, sample_count: 1}}
    assert scraped_at == sample.scraped_at
  end
end
