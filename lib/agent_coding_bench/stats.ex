defmodule AgentCodingBench.Stats do
  @moduledoc """
  Collection and observation windows for serving and workload statistics.
  """

  alias AgentCodingBench.Box
  alias AgentCodingBench.Repo
  alias AgentCodingBench.Stats.Call
  alias AgentCodingBench.Stats.Comparison
  alias AgentCodingBench.Stats.LiveSnapshot
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

  @doc "Lists Runs from newest to oldest for comparison controls."
  @spec list_runs() :: [Run.t()]
  def list_runs do
    Repo.all(from run in Run, order_by: [desc: run.started_at])
  end

  @doc "Builds the current fifteen-minute serving and World activity snapshot."
  @spec live_snapshot(keyword()) :: map()
  def live_snapshot(opts \\ []), do: LiveSnapshot.build(opts)

  @doc "Builds the serving and workload ledger for two Runs."
  @spec compare_runs!(pos_integer(), pos_integer()) :: map()
  def compare_runs!(run_a_id, run_b_id) do
    Comparison.build(Repo.get!(Run, run_a_id), Repo.get!(Run, run_b_id))
  end

  @doc """
  Starts a Run after capturing the serving fingerprint.
  """
  @spec start_run(map(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def start_run(attrs, opts \\ []) when is_map(attrs) do
    box = Keyword.get(opts, :box, configured_box())

    with {:ok, capture} <- box.capture_fingerprint(),
         {:ok, run} <-
           %Run{}
           |> Run.start_changeset(attrs, capture, DateTime.utc_now())
           |> Repo.insert() do
      broadcast_run_status(run, true)
      {:ok, run}
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
        {1, [stopped_run]} ->
          broadcast_run_status(stopped_run, false)
          {:ok, stopped_run}

        {0, []} ->
          already_stopped_error(run)
      end
    end
  end

  def stop_run(%Run{} = run, _opts) do
    already_stopped_error(run)
  end

  defp configured_box do
    Application.get_env(:agent_coding_bench, :stats_box, Box)
  end

  defp broadcast_run_status(run, active?) do
    Phoenix.PubSub.broadcast(
      AgentCodingBench.PubSub,
      "stats",
      {:run_status, %{active?: active?, run_id: run.id}}
    )
  end

  defp already_stopped_error(run) do
    {:error,
     Ecto.Changeset.add_error(Ecto.Changeset.change(run), :ended_at, "run is already stopped")}
  end
end
