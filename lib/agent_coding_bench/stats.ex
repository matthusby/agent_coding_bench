defmodule AgentCodingBench.Stats do
  @moduledoc """
  Collection and observation windows for serving and workload statistics.
  """

  alias AgentCodingBench.Box
  alias AgentCodingBench.Repo
  alias AgentCodingBench.Stats.Call
  alias AgentCodingBench.Stats.Run

  import Ecto.Query, only: [from: 2]

  @doc "Records one client-observed unit of LLM work."
  @spec record_call(map()) :: {:ok, Call.t()} | {:error, Ecto.Changeset.t()}
  def record_call(
        %{
          at: at,
          lane: lane,
          role: role,
          prompt_tokens: prompt_tokens,
          completion_tokens: completion_tokens,
          reasoning_tokens: reasoning_tokens,
          cached_tokens: cached_tokens,
          ttft_ms: ttft_ms,
          duration_ms: duration_ms
        } = attrs
      ) do
    %Call{
      at: at,
      lane: lane,
      role: role,
      task_id: Map.get(attrs, :task_id),
      prompt_tokens: prompt_tokens,
      completion_tokens: completion_tokens,
      reasoning_tokens: reasoning_tokens,
      cached_tokens: cached_tokens,
      ttft_ms: ttft_ms,
      duration_ms: duration_ms
    }
    |> Call.changeset()
    |> Repo.insert()
  end

  @doc """
  Returns the most recently started open Run, if one exists.
  """
  @spec active_run() :: Run.t() | nil
  def active_run do
    Repo.one(
      from run in Run,
        where: is_nil(run.ended_at),
        order_by: [desc: run.started_at],
        limit: 1
    )
  end

  @doc """
  Starts a Run after capturing the serving fingerprint.
  """
  @spec start_run(map(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def start_run(attrs, opts \\ []) when is_map(attrs) do
    box = Keyword.get(opts, :box, configured_box())

    with {:ok, capture} <- box.capture_fingerprint() do
      %Run{}
      |> Run.start_changeset(attrs, capture, DateTime.utc_now())
      |> Repo.insert()
    end
  end

  @doc """
  Stops an open Run and flags it if the serving fingerprint changed.
  """
  @spec stop_run(Run.t(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def stop_run(run, opts \\ [])

  def stop_run(%Run{ended_at: nil} = run, opts) do
    box = Keyword.get(opts, :box, configured_box())

    with {:ok, capture} <- box.capture_fingerprint() do
      stopped_at = DateTime.utc_now()

      query =
        from stored_run in Run,
          where: stored_run.id == ^run.id and is_nil(stored_run.ended_at),
          select: stored_run

      case Repo.update_all(query,
             set: [
               ended_at: stopped_at,
               fingerprint_mismatch: run.fingerprint_digest != capture.digest
             ]
           ) do
        {1, [stopped_run]} -> {:ok, stopped_run}
        {0, []} -> already_stopped_error(run)
      end
    end
  end

  def stop_run(%Run{} = run, _opts) do
    already_stopped_error(run)
  end

  defp configured_box do
    Application.get_env(:agent_coding_bench, :stats_box, Box)
  end

  defp already_stopped_error(run) do
    {:error,
     Ecto.Changeset.add_error(Ecto.Changeset.change(run), :ended_at, "run is already stopped")}
  end
end
