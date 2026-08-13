defmodule AgentCodingBench.Stats do
  @moduledoc """
  Collection and observation windows for serving and workload statistics.
  """

  alias AgentCodingBench.Box
  alias AgentCodingBench.Repo
  alias AgentCodingBench.Stats.Run

  @doc """
  Starts a Run after capturing the serving fingerprint.
  """
  @spec start_run(map(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def start_run(attrs, opts \\ []) when is_map(attrs) do
    box = Keyword.get(opts, :box, Box)

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
    box = Keyword.get(opts, :box, Box)

    with {:ok, capture} <- box.capture_fingerprint() do
      run
      |> Run.stop_changeset(capture, DateTime.utc_now())
      |> Repo.update()
    end
  end

  def stop_run(%Run{} = run, _opts) do
    {:error,
     Ecto.Changeset.add_error(Ecto.Changeset.change(run), :ended_at, "run is already stopped")}
  end
end
