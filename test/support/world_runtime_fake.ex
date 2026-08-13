defmodule AgentCodingBench.WorldRuntimeFake do
  @moduledoc false

  @state_key {__MODULE__, :state}

  def running?, do: :persistent_term.get(@state_key, false)

  def start(_lane_count) do
    :persistent_term.put(@state_key, true)
    {:ok, self()}
  end

  def scale_lanes(_lane_count), do: :ok

  def stop do
    if running?() do
      reset()
      :ok
    else
      {:error, :not_started}
    end
  end

  def reset, do: :persistent_term.erase(@state_key)
end
