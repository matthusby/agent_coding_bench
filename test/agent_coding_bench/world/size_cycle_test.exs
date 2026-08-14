defmodule AgentCodingBench.World.SizeCycleTest do
  use ExUnit.Case, async: true

  alias AgentCodingBench.World.SizeCycle

  test "deals each cycle in the configured proportions" do
    cycle = SizeCycle.new([small: 3, medium: 2, large: 1], shuffle: &Enum.sort/1)

    {picked, _cycle} = Enum.map_reduce(1..12, cycle, fn _, cycle -> SizeCycle.next(cycle) end)

    # Two full cycles: the mix is exact per cycle, not merely exact on average.
    assert Enum.frequencies(picked) == %{small: 6, medium: 4, large: 2}
    assert picked |> Enum.take(6) |> Enum.frequencies() == %{small: 3, medium: 2, large: 1}
  end

  test "reshuffles at every cycle boundary" do
    shuffle = fn slate ->
      count = Process.get(:size_cycle_shuffles, 0)
      Process.put(:size_cycle_shuffles, count + 1)
      if rem(count, 2) == 0, do: slate, else: Enum.reverse(slate)
    end

    cycle = SizeCycle.new([small: 1, large: 1], shuffle: shuffle)

    {picked, _cycle} = Enum.map_reduce(1..4, cycle, fn _, cycle -> SizeCycle.next(cycle) end)

    assert picked == [:small, :large, :large, :small]
    assert Process.get(:size_cycle_shuffles) == 2
  end

  test "drops sizes weighted to zero so a bucket can be switched off" do
    cycle = SizeCycle.new([small: 2, medium: 0, large: 0], shuffle: & &1)

    {picked, _cycle} = Enum.map_reduce(1..4, cycle, fn _, cycle -> SizeCycle.next(cycle) end)

    assert picked == [:small, :small, :small, :small]
  end

  test "refuses a slate with nothing to deal" do
    assert_raise ArgumentError, fn -> SizeCycle.new(small: 0, medium: 0) end
  end
end
