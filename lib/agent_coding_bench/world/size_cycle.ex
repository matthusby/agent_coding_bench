defmodule AgentCodingBench.World.SizeCycle do
  @moduledoc """
  Lane-local, shuffled rotation through the weighted task size slate.

  Weights are dealt as whole slots per cycle rather than sampled per task: a
  `[small: 10, medium: 7, large: 3]` slate hands out exactly ten small, seven
  medium, and three large tasks every twenty, in random order. Independent
  sampling would let a lane draw six larges in a row and skew a short Run, so
  dealing bounds how far the realized mix can drift from the configured one.

  Task size is mechanical for the same reason the World Repo rotation is: the
  load mix is a knob the rig sets, not a judgment the PM makes.
  """

  @enforce_keys [:slate, :remaining, :shuffle]
  defstruct [:slate, :remaining, :shuffle]

  @opaque t :: %__MODULE__{
            slate: [atom()],
            remaining: [atom()],
            shuffle: ([atom()] -> [atom()])
          }

  @doc """
  Creates a rotation from size weights.

  Sizes weighted zero or lower are dropped, so a bucket can be switched off
  without removing its configuration.
  """
  @spec new(keyword(integer()), keyword()) :: t()
  def new(weights, opts \\ []) when is_list(weights) do
    shuffle = Keyword.get(opts, :shuffle, &Enum.shuffle/1)
    slate = expand(weights)

    if slate == [] do
      raise ArgumentError, "task size weights must include at least one positive weight"
    end

    %__MODULE__{slate: slate, remaining: shuffle.(slate), shuffle: shuffle}
  end

  @doc "Returns the next task size and the advanced rotation."
  @spec next(t()) :: {atom(), t()}
  def next(%__MODULE__{remaining: []} = cycle) do
    next(%{cycle | remaining: cycle.shuffle.(cycle.slate)})
  end

  def next(%__MODULE__{remaining: [size | rest]} = cycle) do
    {size, %{cycle | remaining: rest}}
  end

  defp expand(weights) do
    Enum.flat_map(weights, fn {size, weight} when is_atom(size) and is_integer(weight) ->
      List.duplicate(size, max(weight, 0))
    end)
  end
end
