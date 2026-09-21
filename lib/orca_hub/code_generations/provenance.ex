defmodule OrcaHub.CodeGenerations.Provenance do
  @moduledoc """
  Proof of what KIND of process published a code generation, and the
  allowlist deciding whether that kind may ever be hot-loaded onto a node.

  ## The hazard this exists for

  The hub's desired code state lives in the database. On this homelab the
  local systemd PRODUCTION instance and `bin/test` read the SAME database
  (`DB_NAME=orca_hub_dev`), so the two share a table. `mix test` publishes
  generations for real — `test/orca_hub/cluster/code_push_test.exs`
  legitimately exercises the publish path with SYNTHETIC modules compiled
  in-test (`CPTest.Publish.U8132` and friends) — and those rows are
  normally confined to a rolled-back Ecto sandbox transaction.

  "Normally" is the problem. Rows have been observed escaping that sandbox:
  a `GenServer` tick landing inside an `async: false` test's shared-sandbox
  window writes rows that survive the rollback. A `code_generations` row
  escaping that way is not a stray message — it is a row a production hub
  would read on its next boot and hot-load fabricated bytecode from.
  `config :orca_hub, :code_reconcile_enabled, false` keeps the test node
  itself inert, but it says nothing about what OTHER instances do with a
  row the suite left behind.

  So the guard cannot live on the publishing side alone. It has to be
  something the APPLYING node checks about a row it did not write.

  ## The marker

  Every generation is stamped, at insert time, with a marker string that is
  a function of the publishing CODE, not of anything a caller passes in:

      "1:release:prod"     a release build, compiled MIX_ENV=prod
      "1:mix:dev"          `mix phx.server` on a developer's box
      "1:mix:test"         a `mix test` run  <- never trusted
      "1:mix:prod"         `MIX_ENV=prod mix run`, no release

  Fields are `<format version>:<runtime>:<compile env>`.

  The load-bearing field is the last one, and the reason it is trustworthy
  is that it is captured at COMPILE time (`@compile_env Mix.env()`), baked
  into this module's beam. Code compiled by `mix test` says `test` and
  cannot say anything else — there is no runtime switch, no env var and no
  option that changes it. `OrcaHub.CodeGenerations.publish/2` writes
  `current/0` onto the struct BEFORE the changeset runs and never casts the
  field, so no attrs map can override it either.

  The other two fields are provenance for a human reading a status page;
  only the env participates in the trust decision. Keeping the decision
  surface that small is deliberate — every additional condition is another
  way to be wrong about a production instance's own generation.

  ## Trust is an ALLOWLIST, and it fails closed

  `verify/1` returns `:ok` only for a marker it parsed AND whose env is in
  `trusted_envs/0`. Everything else refuses, including:

    * `nil` — every generation row published before this column existed.
      An old row is not grandfathered in; it is refused exactly like a test
      row, because nothing about it proves it was not one. The cost of being
      wrong that way is one republish.
    * a marker in any shape this version does not recognise — a future
      format, a truncated string, a hand-edited value.

  `dev` is trusted and `test` is not, which is the whole distinction: a
  publish from a dev checkout is a deliberate act by a human or agent who
  typed `publish_code_generation`, while a publish from a test run is an
  automatic side effect of running the suite with no intent behind it at
  all.

  ## The test bypass

  The feature's own tests must publish AND apply generations, and they run
  under `mix test`, so they produce exactly the markers production refuses.
  Rather than weakening `verify/1`, `config/test.exs` opts the TEST NODE
  into trusting test provenance:

      config :orca_hub, :trust_test_code_generations, true

  This is the correct place for the switch because it is read by the node
  doing the APPLYING. A production instance never sets it, so a row that
  escapes the sandbox and lands in front of a production hub is refused no
  matter which node wrote it. Tests that want to see the refusal flip the
  key off for themselves.
  """

  # Captured at COMPILE time on purpose — see the moduledoc. Beams compiled
  # by `mix test` carry "test" here permanently.
  @compile_env to_string(Mix.env())

  @format_version "1"

  # Envs whose publishes a node may hot-load. "test" is deliberately absent
  # and must stay absent; the test node opts in through :trust_test_code_generations.
  @trusted_envs ~w(prod dev)

  @bypass_key :trust_test_code_generations

  @type marker :: String.t()
  @type parsed :: %{version: String.t(), runtime: String.t(), env: String.t()}

  @doc """
  The marker for a generation published by THIS running code.

  Not configurable and not overridable: the env half comes from a compile-time
  attribute, and the runtime half from whether a release boot script started us.
  """
  @spec current() :: marker()
  def current, do: Enum.join([@format_version, runtime(), @compile_env], ":")

  @doc "The compile-time `Mix.env()` of the running code, as a string."
  @spec compile_env() :: String.t()
  def compile_env, do: @compile_env

  @doc "Envs a generation may have been published from and still be applied."
  @spec trusted_envs() :: [String.t()]
  def trusted_envs do
    if Application.get_env(:orca_hub, @bypass_key, false),
      do: @trusted_envs ++ ["test"],
      else: @trusted_envs
  end

  @doc """
  Parses a marker. Returns `{:error, :missing}` for a row that has none and
  `{:error, {:unparseable, raw}}` for anything this version cannot read —
  both of which `verify/1` treats as refusals.
  """
  @spec parse(marker() | nil) :: {:ok, parsed()} | {:error, :missing | {:unparseable, term()}}
  def parse(nil), do: {:error, :missing}
  def parse(""), do: {:error, :missing}

  def parse(raw) when is_binary(raw) do
    case String.split(raw, ":") do
      [@format_version, runtime, env] when runtime != "" and env != "" ->
        {:ok, %{version: @format_version, runtime: runtime, env: env}}

      _ ->
        {:error, {:unparseable, raw}}
    end
  end

  def parse(other), do: {:error, {:unparseable, other}}

  @doc """
  `:ok` when a generation carrying `marker` may be applied on this node,
  `{:error, reason}` otherwise. Every non-`:ok` answer is a refusal to load
  the beams — there is no "probably fine" verdict.
  """
  @spec verify(marker() | nil) :: :ok | {:error, term()}
  def verify(marker) do
    case parse(marker) do
      {:ok, %{env: env}} ->
        if env in trusted_envs(), do: :ok, else: {:error, {:untrusted_env, env}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "True when `marker` would be applied on this node. See `verify/1`."
  @spec trusted?(marker() | nil) :: boolean()
  def trusted?(marker), do: verify(marker) == :ok

  @doc """
  Operator-facing prose for a `verify/1` refusal. Deliberately names the
  escaped-test-row scenario: a silently skipped generation is its own
  failure mode, and the person reading the log needs to know that the fix
  is to republish, not to retry.
  """
  @spec describe_refusal(term()) :: String.t()
  def describe_refusal({:untrusted_env, "test"}),
    do:
      "it was published by a TEST RUN (provenance env \"test\"). Test runs share this " <>
        "database and publish generations of synthetic, in-test-compiled modules; such a " <>
        "row must never be hot-loaded onto a live node. Republish from a real checkout."

  def describe_refusal({:untrusted_env, env}),
    do:
      "it was published from the #{inspect(env)} environment, which is not in this node's " <>
        "trusted set (#{Enum.join(trusted_envs(), ", ")}). Republish from a real checkout."

  def describe_refusal(:missing),
    do:
      "it carries NO publish provenance. Generations published before provenance stamping " <>
        "existed read this way, and so would a row inserted by something other than a " <>
        "genuine publish — the two are indistinguishable, so neither is trusted. Republish."

  def describe_refusal({:unparseable, raw}),
    do:
      "its publish provenance #{inspect(raw)} is not in a format this node understands " <>
        "(expected \"#{@format_version}:<runtime>:<env>\"). An unreadable marker is a " <>
        "refusal, never a pass. Republish."

  def describe_refusal(other), do: "its publish provenance was rejected: #{inspect(other)}"

  # A release's boot script exports RELEASE_NAME; `mix`-driven runs do not.
  # Informational only — no trust decision reads this.
  defp runtime do
    case System.get_env("RELEASE_NAME") do
      name when is_binary(name) and name != "" -> "release"
      _ -> "mix"
    end
  end
end
