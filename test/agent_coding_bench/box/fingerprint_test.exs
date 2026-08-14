defmodule AgentCodingBench.Box.FingerprintTest do
  use ExUnit.Case, async: true

  alias AgentCodingBench.Box.Fingerprint

  test "capture reads the AITER version from distribution metadata" do
    exec = fn command, _opts ->
      cond do
        String.contains?(command, "docker image inspect") ->
          {"example/image@sha256:digest\n", 0}

        String.contains?(command, "{{json .Config.Cmd}}") ->
          {~s(["--model","example"]), 0}

        String.contains?(command, "{{json .Config.Env}}") ->
          {~s(["VLLM_USE_V1=1"]), 0}

        String.contains?(command, "sha256sum -c") ->
          {"weights: OK\n", 0}

        String.contains?(command, "sha256sum SHA256SUMS") ->
          {String.duplicate("a", 64) <> "  SHA256SUMS\n", 0}

        String.contains?(command, "Initializing a V1 LLM engine") ->
          {"Initializing a V1 LLM engine with config: example\n", 0}

        String.contains?(command, ~s|metadata.version("amd-aiter")|) ->
          {"0.1.19\n", 0}

        true ->
          {"unexpected command: #{command}", 1}
      end
    end

    request = fn opts ->
      case {Keyword.fetch!(opts, :method), Keyword.fetch!(opts, :url)} do
        {:get, "http://vllm.test/version"} ->
          {:ok, %{status: 200, body: %{"version" => "0.10.1"}}}

        {:get, "http://vllm.test/v1/models"} ->
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => [
                 %{"id" => "example", "root" => "/models/example", "max_model_len" => 4096}
               ]
             }
           }}

        {:post, "http://vllm.test/v1/completions"} ->
          {:ok, %{status: 200, body: %{"system_fingerprint" => "fp-example"}}}

        {:get, "http://vllm.test/metrics"} ->
          {:ok, %{status: 200, body: "vllm:num_requests_running 0\n"}}
      end
    end

    assert {:ok, %{fingerprint: fingerprint}} =
             Fingerprint.capture(exec, request, "http://vllm.test")

    assert fingerprint["aiter_version"] == "0.1.19"
  end

  test "canonical JSON sorts object keys recursively without reordering arrays" do
    fingerprint = %{
      "z" => 0,
      "list" => [%{"d" => 4, "c" => 3}],
      "a" => %{"b" => 2, "a" => 1}
    }

    assert Fingerprint.canonical_json(fingerprint) ==
             ~s({"a":{"a":1,"b":2},"list":[{"c":3,"d":4}],"z":0})
  end

  test "digest is the lowercase SHA-256 of the canonical JSON" do
    fingerprint = %{
      "z" => 0,
      "list" => [%{"d" => 4, "c" => 3}],
      "a" => %{"b" => 2, "a" => 1}
    }

    assert Fingerprint.digest(fingerprint) ==
             "984ae617199b20a3a7abba5e6f32b62287d4671ee91b666b8b6c759cd158d57b"
  end

  test "digest excludes the live metrics snapshot" do
    stable_facts = %{"model" => "deepseek-v4"}

    assert Fingerprint.digest(Map.put(stable_facts, "metrics_snapshot_t0", "counter 1")) ==
             Fingerprint.digest(Map.put(stable_facts, "metrics_snapshot_t0", "counter 2"))
  end

  test "digest ignores the engine config line's pid and timestamp" do
    stable_facts = %{"model" => "deepseek-v4"}
    config = "Initializing a V1 LLM engine (v0.26.1) with config: model='deepseek-v4'"

    before_restart =
      "inference-1  | (EngineCore pid=345) INFO 08-14 01:03:28 [core.py:121] " <> config

    after_restart =
      "inference-1  | (EngineCore pid=90) INFO 08-14 03:43:41 [core.py:121] " <> config

    assert Fingerprint.digest(Map.put(stable_facts, "engine_config_line", before_restart)) ==
             Fingerprint.digest(Map.put(stable_facts, "engine_config_line", after_restart))
  end

  test "digest still tracks a real change to the engine config" do
    stable_facts = %{"model" => "deepseek-v4"}
    prefix = "inference-1  | (EngineCore pid=345) INFO 08-14 01:03:28 [core.py:121] "
    engine = "Initializing a V1 LLM engine (v0.26.1) with config: max_seq_len="

    digest_for = fn max_seq_len ->
      stable_facts
      |> Map.put("engine_config_line", prefix <> engine <> max_seq_len)
      |> Fingerprint.digest()
    end

    refute digest_for.("262144") == digest_for.("131072")
  end
end
