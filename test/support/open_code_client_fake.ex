defmodule AgentCodingBench.OpenCodeClientFake do
  @moduledoc false

  def request(params) do
    opts = Map.fetch!(params, :opts)
    send(Keyword.fetch!(opts, :test_pid), {:opencode_request, params})
    Keyword.fetch!(opts, :response)
  end
end
