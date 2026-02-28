defmodule OrcaHubWeb.PageController do
  use OrcaHubWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
