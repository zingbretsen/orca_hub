defmodule OrcaHubWeb.EnvAllowlistInputTest do
  use ExUnit.Case, async: true

  alias OrcaHubWeb.EnvAllowlistInput

  describe "parse/1" do
    test "splits on commas, spaces, and newlines" do
      assert EnvAllowlistInput.parse("AWS_*, MY_TOKEN\nOTHER_VAR") ==
               ["AWS_*", "MY_TOKEN", "OTHER_VAR"]
    end

    test "drops blank tokens from repeated separators" do
      assert EnvAllowlistInput.parse("AWS_*,,  MY_TOKEN,") == ["AWS_*", "MY_TOKEN"]
    end

    test "empty/nil input yields an empty list" do
      assert EnvAllowlistInput.parse("") == []
      assert EnvAllowlistInput.parse(nil) == []
    end
  end

  describe "to_text/1" do
    test "joins entries with a comma+space" do
      assert EnvAllowlistInput.to_text(["AWS_*", "MY_TOKEN"]) == "AWS_*, MY_TOKEN"
    end

    test "empty list and non-list both render as empty string" do
      assert EnvAllowlistInput.to_text([]) == ""
      assert EnvAllowlistInput.to_text(nil) == ""
    end
  end
end
