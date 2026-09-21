defmodule OrcaHub.CodeGenerations.ProvenanceTest do
  @moduledoc """
  The publish-provenance allowlist. These are pure unit tests — the
  integration side (a production-shaped node refusing to APPLY a test-run
  generation) lives in `OrcaHub.Cluster.CodePushTest`.

  The property being pinned is that every answer other than an explicitly
  trusted, parseable marker is a REFUSAL. There is no "looks fine" verdict,
  and in particular no grandfathering of rows that predate the column.
  """

  use ExUnit.Case, async: false

  alias OrcaHub.CodeGenerations.Provenance

  setup do
    previous = Application.fetch_env(:orca_hub, :trust_test_code_generations)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:orca_hub, :trust_test_code_generations, value)
        :error -> Application.delete_env(:orca_hub, :trust_test_code_generations)
      end
    end)

    :ok
  end

  defp distrust_test_runs, do: Application.put_env(:orca_hub, :trust_test_code_generations, false)

  describe "current/0 — the stamp this code produces" do
    test "names the COMPILE-TIME env, which under mix test is always \"test\"" do
      assert Provenance.compile_env() == "test"
      assert {:ok, %{env: "test", version: "1"}} = Provenance.parse(Provenance.current())
    end

    test "is parseable by this version's own parser" do
      assert {:ok, %{runtime: runtime}} = Provenance.parse(Provenance.current())
      assert runtime in ~w(mix release)
    end
  end

  describe "parse/1" do
    test "reads a well-formed marker" do
      assert {:ok, %{version: "1", runtime: "release", env: "prod"}} =
               Provenance.parse("1:release:prod")
    end

    test "a missing marker is :missing, not a parse error" do
      assert Provenance.parse(nil) == {:error, :missing}
      assert Provenance.parse("") == {:error, :missing}
    end

    test "anything this version cannot read is unparseable, never a pass" do
      for raw <- [
            "prod",
            "1:prod",
            "1:release:prod:extra",
            "2:release:prod",
            "1::prod",
            "1:release:",
            :not_a_string,
            123
          ] do
        assert {:error, {:unparseable, ^raw}} = Provenance.parse(raw),
               "expected #{inspect(raw)} to be refused as unparseable"
      end
    end
  end

  describe "verify/1 — the allowlist, which fails closed" do
    test "trusts a release/prod publish" do
      distrust_test_runs()
      assert Provenance.verify("1:release:prod") == :ok
      assert Provenance.verify("1:mix:prod") == :ok
    end

    test "trusts a dev publish — a human typed publish_code_generation" do
      distrust_test_runs()
      assert Provenance.verify("1:mix:dev") == :ok
    end

    test "REFUSES a test-run publish on a node that has not opted in" do
      distrust_test_runs()
      assert {:error, {:untrusted_env, "test"}} = Provenance.verify("1:mix:test")
      refute Provenance.trusted?(Provenance.current())
    end

    test "REFUSES a row with no provenance — an old row is not grandfathered" do
      distrust_test_runs()
      assert Provenance.verify(nil) == {:error, :missing}
      assert Provenance.verify("") == {:error, :missing}
      refute Provenance.trusted?(nil)
    end

    test "REFUSES an unrecognised marker rather than guessing at it" do
      distrust_test_runs()
      assert {:error, {:unparseable, "9:mix:prod"}} = Provenance.verify("9:mix:prod")
      assert {:error, {:unparseable, "garbage"}} = Provenance.verify("garbage")
    end

    test "REFUSES an env nobody has allowlisted" do
      distrust_test_runs()
      assert {:error, {:untrusted_env, "staging"}} = Provenance.verify("1:release:staging")
    end

    test "the test bypass is opt-in per APPLYING node and covers only \"test\"" do
      Application.put_env(:orca_hub, :trust_test_code_generations, true)

      assert Provenance.verify("1:mix:test") == :ok
      assert Provenance.trusted?(Provenance.current())

      # Still an allowlist — the bypass adds one env, it does not open the gate.
      assert {:error, {:untrusted_env, "staging"}} = Provenance.verify("1:mix:staging")
      assert Provenance.verify(nil) == {:error, :missing}
      assert {:error, {:unparseable, _}} = Provenance.verify("nope")
    end
  end

  describe "describe_refusal/1" do
    test "names the escaped-test-row scenario explicitly" do
      message = Provenance.describe_refusal({:untrusted_env, "test"})
      assert message =~ "TEST RUN"
      assert message =~ "Republish"
    end

    test "says plainly that an absent marker is not a trusted one" do
      assert Provenance.describe_refusal(:missing) =~ "NO publish provenance"
    end

    test "quotes the marker it could not read" do
      assert Provenance.describe_refusal({:unparseable, "junk"}) =~ "junk"
    end
  end
end
