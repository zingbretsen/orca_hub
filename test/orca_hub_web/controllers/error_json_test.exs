defmodule OrcaHubWeb.ErrorJSONTest do
  use OrcaHubWeb.ConnCase, async: true

  test "renders 404" do
    assert OrcaHubWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert OrcaHubWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
