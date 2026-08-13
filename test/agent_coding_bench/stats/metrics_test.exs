defmodule AgentCodingBench.Stats.MetricsTest do
  use ExUnit.Case, async: true

  alias AgentCodingBench.Stats.Metrics

  test "parse keeps every vLLM sample raw and ignores other metric families" do
    scraped_at = ~U[2026-08-13 12:00:00.123456Z]

    exposition = """
    # HELP vllm:num_requests_running Number of requests currently running.
    # TYPE vllm:num_requests_running gauge
    vllm:num_requests_running{engine="0",model_name="deepseek-v4"} 2
    vllm:request_success_total{finished_reason="stop"} 41 1755086400
    vllm:prompt_tokens_total 1234
    process_cpu_seconds_total 99
    """

    assert {:ok, samples} = Metrics.parse(exposition, scraped_at)

    assert samples == [
             %{
               scraped_at: scraped_at,
               metric: "vllm:num_requests_running",
               labels: %{"engine" => "0", "model_name" => "deepseek-v4"},
               value: 2.0
             },
             %{
               scraped_at: scraped_at,
               metric: "vllm:request_success_total",
               labels: %{"finished_reason" => "stop"},
               value: 41.0
             },
             %{
               scraped_at: scraped_at,
               metric: "vllm:prompt_tokens_total",
               labels: %{},
               value: 1234.0
             }
           ]
  end

  test "parse decodes Prometheus label escapes" do
    exposition = ~s(vllm:test{path="C:\\\\models",message="say \\\"hi\\\"\\nnow"} 1\n)

    assert {:ok, [%{labels: labels}]} = Metrics.parse(exposition, DateTime.utc_now())
    assert labels == %{"path" => "C:\\models", "message" => "say \"hi\"\nnow"}
  end

  test "parse reports a malformed vLLM sample instead of dropping it" do
    assert {:error, {:invalid_sample, "vllm:broken"}} =
             Metrics.parse("vllm:broken\n", DateTime.utc_now())
  end
end
