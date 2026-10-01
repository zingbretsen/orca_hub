defmodule OrcaHub.Triggers.TriggerBackendModelTest do
  @moduledoc """
  `Trigger.backend`/`model` changeset rules: backend is validated against the
  known backends when present, model is free text, and blank strings mean
  "inherit the default" (nil) so the form's empty choice round-trips.
  """

  use ExUnit.Case, async: true

  alias OrcaHub.Triggers.Trigger

  @base %{
    name: "pinned",
    prompt: "do the thing",
    project_id: Ecto.UUID.generate(),
    cron_expression: "0 3 * * *"
  }

  defp changeset(attrs), do: Trigger.changeset(%Trigger{}, Map.merge(@base, attrs))

  test "accepts each known backend with a model" do
    for backend <- ~w(claude codex pi) do
      cs = changeset(%{backend: backend, model: "some/model"})
      assert cs.valid?, "#{backend} should be valid"
      assert Ecto.Changeset.get_field(cs, :backend) == backend
      assert Ecto.Changeset.get_field(cs, :model) == "some/model"
    end
  end

  test "rejects an unknown backend" do
    cs = changeset(%{backend: "gemini"})
    refute cs.valid?
    assert {_, [validation: :inclusion, enum: _]} = cs.errors[:backend]
  end

  test "nil backend/model is valid and stays nil (inherit the default)" do
    cs = changeset(%{})
    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :backend) == nil
    assert Ecto.Changeset.get_field(cs, :model) == nil
  end

  test "blank and whitespace-only strings normalize to nil" do
    for blank <- ["", "   "] do
      cs = changeset(%{backend: blank, model: blank})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :backend) == nil
      assert Ecto.Changeset.get_field(cs, :model) == nil
    end
  end

  test "clearing an existing pin with blanks sets both back to nil" do
    existing = %Trigger{backend: "claude", model: "claude-opus-5-5"}
    cs = Trigger.changeset(existing, Map.merge(@base, %{backend: "", model: " "}))

    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :backend) == nil
    assert Ecto.Changeset.get_field(cs, :model) == nil
  end

  test "surrounding whitespace on a model id is trimmed" do
    cs = changeset(%{model: "  claude-opus-5-5 "})
    assert Ecto.Changeset.get_field(cs, :model) == "claude-opus-5-5"
  end
end
