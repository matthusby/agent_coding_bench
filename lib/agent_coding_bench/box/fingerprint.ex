defmodule AgentCodingBench.Box.Fingerprint do
  @moduledoc """
  Captures and fingerprints the serving configuration on the box.
  """

  @container "deepseek-v4-inference-1"
  @serving_repo "~/dev/deepseek-v4-flash-mi300x"
  @ssh_opts [stderr_to_stdout: true]

  @image_command "docker image inspect $(docker inspect #{@container} --format '{{.Image}}') --format '{{index .RepoDigests 0}}'"
  @cmd_command "docker inspect #{@container} --format '{{json .Config.Cmd}}'"
  @env_command "docker inspect #{@container} --format '{{json .Config.Env}}'"
  @sha_check_command "cd #{@serving_repo} && sha256sum -c SHA256SUMS"
  @sha_digest_command "cd #{@serving_repo} && sha256sum SHA256SUMS"
  @engine_marker "Initializing a V1 LLM engine"
  @engine_command "cd #{@serving_repo} && docker compose logs inference 2>&1 | grep '#{@engine_marker}' | tail -n 1"
  @aiter_command "docker exec #{@container} python3 -c 'import importlib.metadata as metadata; print(metadata.version(\"amd-aiter\"))'"

  @doc """
  Collects the authoritative SSH and HTTP facts for the running vLLM server.
  """
  @spec capture(function(), function(), String.t()) ::
          {:ok, %{fingerprint: map(), digest: String.t()}} | {:error, term()}
  def capture(exec, request, vllm_url) do
    vllm_url = String.trim_trailing(vllm_url, "/")

    with {:ok, image_digest} <- ssh_fact(exec, :image_digest, @image_command),
         {:ok, cmd_json} <- ssh_fact(exec, :cmd, @cmd_command),
         {:ok, cmd} <- decode_json(cmd_json, :cmd),
         {:ok, env_json} <- ssh_fact(exec, :env, @env_command),
         {:ok, env_entries} <- decode_json(env_json, :env),
         {:ok, env} <- env_map(env_entries),
         {:ok, sha256sums_ok} <- checksum_ok(exec),
         {:ok, sha_output} <- ssh_fact(exec, :sha256sums_digest, @sha_digest_command),
         {:ok, sha256sums_digest} <- parse_sha_digest(sha_output),
         {:ok, engine_config_line} <- ssh_fact(exec, :engine_config_line, @engine_command),
         {:ok, aiter_version} <- ssh_fact(exec, :aiter_version, @aiter_command),
         {:ok, version_body} <- http(request, :get, vllm_url <> "/version"),
         {:ok, vllm_version} <- fetch_string(version_body, "version", :vllm_version),
         {:ok, models_body} <- http(request, :get, vllm_url <> "/v1/models"),
         {:ok, model} <- first_model(models_body),
         {:ok, model_id} <- fetch_string(model, "id", :model_id),
         {:ok, completion_body} <-
           http(request, :post, vllm_url <> "/v1/completions",
             json: %{"model" => model_id, "prompt" => "x", "max_tokens" => 1}
           ),
         {:ok, system_fingerprint} <-
           fetch_string(completion_body, "system_fingerprint", :system_fingerprint),
         {:ok, metrics_body} <- http(request, :get, vllm_url <> "/metrics"),
         {:ok, metrics_snapshot_t0} <- require_string(metrics_body, :metrics_snapshot_t0),
         {:ok, model_root} <- fetch_string(model, "root", :model_root),
         {:ok, max_model_len} <- fetch_integer(model, "max_model_len", :max_model_len) do
      fingerprint = %{
        "image_digest" => image_digest,
        "cmd" => cmd,
        "env" => env,
        "sha256sums_ok" => sha256sums_ok,
        "sha256sums_digest" => sha256sums_digest,
        "engine_config_line" => engine_config_line,
        "aiter_version" => aiter_version,
        "vllm_version" => vllm_version,
        "model_id" => model_id,
        "model_root" => model_root,
        "max_model_len" => max_model_len,
        "system_fingerprint" => system_fingerprint,
        "metrics_snapshot_t0" => metrics_snapshot_t0
      }

      {:ok, %{fingerprint: fingerprint, digest: digest(fingerprint)}}
    end
  end

  @doc """
  Encodes fingerprint data as JSON with object keys sorted recursively.

  Array order is preserved because it can carry configuration meaning.
  """
  @spec canonical_json(Jason.Encoder.t()) :: String.t()
  def canonical_json(fingerprint) do
    fingerprint
    |> order_objects()
    |> Jason.encode!()
  end

  @doc """
  Returns the lowercase SHA-256 digest of the stable serving configuration.

  The raw t0 metrics snapshot remains part of the stored fingerprint, but is
  excluded from the digest because metric values change during normal traffic.

  The engine config line keeps its raw log prefix in storage, where the pid and
  timestamp say when the engine last started, but the prefix is dropped here so
  that restarting an unchanged engine leaves the digest alone.
  """
  @spec digest(Jason.Encoder.t()) :: String.t()
  def digest(fingerprint) do
    fingerprint
    |> without_metrics_snapshot()
    |> with_stable_engine_config_line()
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp without_metrics_snapshot(fingerprint) when is_map(fingerprint) do
    fingerprint
    |> Map.delete("metrics_snapshot_t0")
    |> Map.delete(:metrics_snapshot_t0)
  end

  defp without_metrics_snapshot(fingerprint), do: fingerprint

  defp with_stable_engine_config_line(fingerprint) when is_map(fingerprint) do
    Enum.reduce([:engine_config_line, "engine_config_line"], fingerprint, fn key, acc ->
      case Map.fetch(acc, key) do
        {:ok, line} when is_binary(line) -> Map.put(acc, key, stable_engine_config_line(line))
        _ -> acc
      end
    end)
  end

  defp with_stable_engine_config_line(fingerprint), do: fingerprint

  # Drops the "inference-1  | (EngineCore pid=345) INFO 08-14 01:03:28
  # [core.py:121] " prefix. The pid and timestamp change on every engine
  # restart; the rest of the prefix is either constant or already covered by
  # the vllm_version field.
  defp stable_engine_config_line(line) do
    case String.split(line, @engine_marker, parts: 2) do
      [_prefix, rest] -> @engine_marker <> rest
      _ -> line
    end
  end

  defp order_objects(value) when is_map(value) do
    value
    |> Enum.map(fn {key, child} -> {to_string(key), order_objects(child)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp order_objects(value) when is_list(value), do: Enum.map(value, &order_objects/1)
  defp order_objects(value), do: value

  defp ssh_fact(exec, name, command) do
    case exec.(command, @ssh_opts) do
      {output, 0} when is_binary(output) -> nonempty_ssh_fact(output, name)
      {output, status} -> {:error, {:ssh, name, status, output}}
    end
  end

  defp nonempty_ssh_fact(output, name) do
    case String.trim(output) do
      "" -> {:error, {:ssh, name, 0, output}}
      value -> {:ok, value}
    end
  end

  defp checksum_ok(exec) do
    case exec.(@sha_check_command, @ssh_opts) do
      {_output, status} when is_integer(status) -> {:ok, status == 0}
      result -> {:error, {:ssh, :sha256sums_ok, result}}
    end
  end

  defp decode_json(json, name) do
    case Jason.decode(json) do
      {:ok, value} -> {:ok, value}
      {:error, error} -> {:error, {:invalid_ssh_json, name, error}}
    end
  end

  defp env_map(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, env} ->
      if is_binary(entry) do
        case String.split(entry, "=", parts: 2) do
          [key, value] ->
            {:cont, {:ok, Map.put(env, key, value)}}

          # Docker records a variable declared without a value - Compose's
          # `VAR: null`, which leaves it unset in the container - as a bare
          # name. That is a real serving configuration, so it belongs in the
          # fingerprint; `nil` keeps it distinct from both an absent key and an
          # empty `VAR=`.
          [key] when key != "" ->
            {:cont, {:ok, Map.put(env, key, nil)}}

          _ ->
            {:halt, {:error, {:invalid_container_env, entry}}}
        end
      else
        {:halt, {:error, {:invalid_container_env, entry}}}
      end
    end)
  end

  defp env_map(value), do: {:error, {:invalid_container_env, value}}

  defp parse_sha_digest(output) do
    case String.split(output, ~r/\s+/, parts: 2) do
      [digest, _filename] -> validate_sha_digest(digest, output)
      _ -> {:error, {:invalid_sha256sums_digest, output}}
    end
  end

  defp validate_sha_digest(digest, output) do
    if Regex.match?(~r/\A[0-9a-fA-F]{64}\z/, digest) do
      {:ok, String.downcase(digest)}
    else
      {:error, {:invalid_sha256sums_digest, output}}
    end
  end

  defp http(request, method, url, opts \\ []) do
    request_opts = [method: method, url: url] ++ opts

    case request.(request_opts) do
      {:ok, %{status: status, body: body}} when status >= 200 and status < 300 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http, method, url, status, body}}
      {:error, reason} -> {:error, {:http, method, url, reason}}
    end
  end

  defp first_model(%{"data" => [model | _]}) when is_map(model), do: {:ok, model}
  defp first_model(body), do: {:error, {:invalid_models_response, body}}

  defp fetch_string(map, key, name) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_http_field, name, map}}
    end
  end

  defp fetch_string(value, _key, name), do: {:error, {:invalid_http_field, name, value}}

  defp fetch_integer(map, key, name) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      _ -> {:error, {:invalid_http_field, name, map}}
    end
  end

  defp fetch_integer(value, _key, name), do: {:error, {:invalid_http_field, name, value}}

  defp require_string(value, _name) when is_binary(value), do: {:ok, value}
  defp require_string(value, name), do: {:error, {:invalid_http_field, name, value}}
end
