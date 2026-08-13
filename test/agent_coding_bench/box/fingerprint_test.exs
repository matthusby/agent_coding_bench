defmodule AgentCodingBench.Box.FingerprintTest do
  use ExUnit.Case, async: true

  alias AgentCodingBench.Box.Fingerprint

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
end
