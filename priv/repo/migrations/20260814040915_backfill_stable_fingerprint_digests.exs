defmodule AgentCodingBench.Repo.Migrations.BackfillStableFingerprintDigests do
  use Ecto.Migration

  alias AgentCodingBench.Box.Fingerprint

  @doc """
  Recomputes stored digests now that `Fingerprint.digest/1` drops the engine
  config line's log prefix.

  Digests recorded before this cannot compare against ones recorded after, so
  every Run captured on an earlier engine would read as a config change. The
  stored fingerprints are untouched and still carry the raw line, so the new
  digest is derivable from what is already on disk.

  This calls into application code on purpose: reimplementing the canonical
  JSON and hashing here would be a second copy to keep in sync.
  """
  def up do
    {:ok, %{rows: rows}} = repo().query("SELECT id, fingerprint FROM runs")

    Enum.each(rows, fn [id, fingerprint] ->
      repo().query!("UPDATE runs SET fingerprint_digest = $1 WHERE id = $2", [
        Fingerprint.digest(fingerprint),
        id
      ])
    end)
  end

  # The pre-strip digests are not recoverable from stored data, and rolling
  # back the code restores the old algorithm for anything captured afterwards.
  def down, do: :ok
end
