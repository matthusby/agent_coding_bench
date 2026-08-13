defmodule AgentCodingBench.Box do
  @moduledoc """
  Access to the remote box and the services reached through its SSH tunnel.

  This context is the only place that reads the box host or service URLs.
  """

  alias AgentCodingBench.Box.Fingerprint

  @callback exec(String.t(), keyword()) :: {String.t(), non_neg_integer()}
  @callback capture_fingerprint() ::
              {:ok, %{fingerprint: map(), digest: String.t()}} | {:error, term()}
  @callback scrape_metrics() :: {:ok, String.t()} | {:error, term()}

  @doc """
  Returns the configured URL of the opencode server on the box.
  """
  @spec opencode_url() :: String.t()
  def opencode_url, do: config!(:opencode_url)

  @doc """
  Runs `command` on the configured box through OpenSSH.

  Options other than `:host` are passed to `System.cmd/3`.
  """
  @spec exec(String.t(), keyword()) :: {String.t(), non_neg_integer()}
  def exec(command, opts) when is_binary(command) and is_list(opts) do
    {host, cmd_opts} = Keyword.pop(opts, :host, config!(:host))

    System.cmd("ssh", [host, command], cmd_opts)
  end

  @doc """
  Captures the serving configuration and its deterministic digest.
  """
  @spec capture_fingerprint() ::
          {:ok, %{fingerprint: map(), digest: String.t()}} | {:error, term()}
  def capture_fingerprint do
    Fingerprint.capture(&exec/2, &Req.request/1, config!(:vllm_url))
  end

  @doc """
  Fetches the raw Prometheus exposition from vLLM.
  """
  @spec scrape_metrics() :: {:ok, String.t()} | {:error, term()}
  def scrape_metrics do
    url = String.trim_trailing(config!(:vllm_url), "/") <> "/metrics"

    case Req.get(url: url) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, :get, url, status, body}}

      {:error, reason} ->
        {:error, {:http, :get, url, reason}}
    end
  end

  defp config!(key) do
    :agent_coding_bench
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(key)
  end
end
