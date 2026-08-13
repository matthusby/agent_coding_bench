defmodule AgentCodingBench.World.RepoCycleTest do
  use ExUnit.Case, async: true

  alias AgentCodingBench.World.RepoCycle

  test "walks every World Repo once per shuffled cycle without boundary streaks" do
    shuffle = fn repos ->
      case Process.get(:repo_cycle_shuffle_count, 0) do
        0 ->
          Process.put(:repo_cycle_shuffle_count, 1)
          repos

        _cycle ->
          Enum.reverse(repos)
      end
    end

    cycle = RepoCycle.new([:alpha, :beta, :gamma], shuffle: shuffle)

    {picked, _cycle} =
      Enum.map_reduce(1..6, cycle, fn _, cycle ->
        RepoCycle.next(cycle)
      end)

    assert picked == [:alpha, :beta, :gamma, :beta, :gamma, :alpha]
    assert Enum.chunk_every(picked, 2, 1, :discard) |> Enum.all?(fn [a, b] -> a != b end)
  end
end
