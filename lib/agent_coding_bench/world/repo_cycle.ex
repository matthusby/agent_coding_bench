defmodule AgentCodingBench.World.RepoCycle do
  @moduledoc """
  Lane-local, shuffled rotation through the configured World Repo slate.

  Every World Repo is selected exactly once per cycle. For slates with more
  than one entry, reshuffling also avoids repeating the prior cycle's final
  selection at the boundary.
  """

  @enforce_keys [:repos, :remaining, :shuffle]
  defstruct [:repos, :remaining, :last, :shuffle]

  @opaque t(repo) :: %__MODULE__{
            repos: [repo],
            remaining: [repo],
            last: repo | nil,
            shuffle: ([repo] -> [repo])
          }

  @doc "Creates a rotation for a non-empty World Repo slate."
  @spec new([repo], keyword()) :: t(repo) when repo: term()
  def new(repos, opts \\ []) when is_list(repos) and repos != [] do
    shuffle = Keyword.get(opts, :shuffle, &Enum.shuffle/1)
    remaining = shuffle.(repos)

    %__MODULE__{repos: repos, remaining: remaining, last: nil, shuffle: shuffle}
  end

  @doc "Returns the next World Repo and the advanced rotation."
  @spec next(t(repo)) :: {repo, t(repo)} when repo: term()
  def next(%__MODULE__{remaining: []} = cycle) do
    remaining = cycle.repos |> cycle.shuffle.() |> avoid_boundary_streak(cycle.last)
    next(%{cycle | remaining: remaining})
  end

  def next(%__MODULE__{remaining: [repo | rest]} = cycle) do
    {repo, %{cycle | remaining: rest, last: repo}}
  end

  defp avoid_boundary_streak([last, next | rest], last), do: [next, last | rest]
  defp avoid_boundary_streak(repos, _last), do: repos
end
