defmodule AgentCodingBenchWeb.PageController do
  use AgentCodingBenchWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
