defmodule AgentCodingBench.BoxFake do
  @moduledoc false

  def put_fingerprint(fingerprint, digest) do
    Process.put({__MODULE__, :capture}, {:ok, %{fingerprint: fingerprint, digest: digest}})
  end

  def capture_fingerprint do
    Process.get(
      {__MODULE__, :capture},
      {:ok, %{fingerprint: %{"model" => "test-model"}, digest: "test-digest"}}
    )
  end

  def scrape_metrics do
    {:ok, "vllm:num_requests_running{engine=\"0\"} 3\nignored_metric 8\n"}
  end
end
