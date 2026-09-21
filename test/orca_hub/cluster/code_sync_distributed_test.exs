defmodule OrcaHub.Cluster.CodeSyncDistributedTest do
  @moduledoc """
  Real two-node coverage for `OrcaHub.Cluster.CodeSync`, including a genuine
  CROSS-ERTS push.

  The ERTS gate is the one rule here that cannot be proved by unit-testing
  the comparison: what matters is that `push/3` refuses *before* reaching the
  code server on a node whose runtime differs. To assert that against a real
  runtime, `alt_erts_peer/0` starts the peer from a DIFFERENT OTP
  installation on this box (any `~/.local/share/mise/installs/erlang/*/bin/erl`
  whose `erlang:system_info(version)` differs from ours). On the dev host
  today that is OTP 27.2.3 / erts-15.2.2 — the exact runtime the fleet was
  built with — against the host toolchain's erts-15.2.7.9, i.e. the real
  newer-compiler-to-older-runtime hazard this gate exists for.

  If no second OTP is installed, those tests skip themselves loudly rather
  than passing vacuously; the rest of the file still gives real cross-node
  coverage of load / skip-identical / drift / purge-refusal.

  Tagged `:distributed` and `async: false` per test_helper.exs: making the
  test VM a live distributed node is process-wide state that breaks
  unrelated async tests.

      mix test --only distributed test/orca_hub/cluster/code_sync_distributed_test.exs

  On a host that also runs a live OrcaHub node, run it with a THROWAWAY
  cookie so the test VM cannot join the real fleet — a running hub reconciles
  its published code generation onto anything that connects to it
  (`OrcaHub.Cluster.CodePush`), and this VM does become a real distributed
  node. Either of these isolates it; see `cookie_args/0` for why the second
  needs that flag to be the only one:

      HOME=$(mktemp -d) bin/test --only distributed <this file>
      ERL_AFLAGS="-setcookie $(openssl rand -hex 16)" bin/test --only distributed <this file>
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :distributed

  alias OrcaHub.Cluster.CodeSync

  @erlang_install_glob "~/.local/share/mise/installs/erlang/*/bin/erl"

  setup_all do
    # A real :nodeup makes ClusterNodeTracker write to the DB from its own
    # process, outside any sandbox — same reason cluster_distributed_test.exs
    # parks it for the duration.
    tracker_stopped? =
      match?(:ok, Supervisor.terminate_child(OrcaHub.Supervisor, OrcaHub.ClusterNodeTracker))

    on_exit(fn ->
      if tracker_stopped? do
        Supervisor.restart_child(OrcaHub.Supervisor, OrcaHub.ClusterNodeTracker)
      end
    end)

    unless Node.alive?() do
      {:ok, hostname} = :inet.gethostname()
      {:ok, _} = Node.start(:"code_sync_test@#{hostname}", :shortnames)
    end

    :ok
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp compile_subject(mod, version) do
    source = """
    defmodule #{inspect(mod)} do
      def version, do: #{version}

      def loop do
        receive do
          {:ping, from} -> send(from, {:pong, version()}); loop()
          :stop -> :ok
        end
      end
    end
    """

    {[{^mod, binary}], _warning} = with_io(:stderr, fn -> Code.compile_string(source) end)
    {:ok, {^mod, md5}} = :beam_lib.md5(binary)
    %{module: mod, binary: binary, md5: md5, path: ~c"/tmp/#{mod}.beam"}
  end

  defp unique_subject_name do
    :"Elixir.OrcaHub.CodeSyncDistTestSubject#{System.unique_integer([:positive])}"
  end

  defp cleanup_subject(mod) do
    on_exit(fn ->
      :code.purge(mod)
      :code.delete(mod)
      :code.purge(mod)
    end)
  end

  defp start_peer(opts) do
    name = :"code_sync_peer_#{System.unique_integer([:positive])}"

    opts =
      opts
      |> Map.put(:name, name)
      |> Map.put(:args, Map.get(opts, :args, []) ++ cookie_args())

    case :peer.start(opts) do
      {:ok, pid, node} ->
        on_exit(fn ->
          try do
            :peer.stop(pid)
          catch
            _, _ -> :ok
          end
        end)

        {:ok, node}

      other ->
        other
    end
  end

  # Never inspected/printed anywhere — the cookie must not reach a log.
  #
  # `:peer` spawns a fresh `erl`, which inherits our ENVIRONMENT (and so any
  # `-setcookie` in ERL_AFLAGS/ERL_FLAGS/ERL_ZFLAGS) but not our argv. Adding
  # our own `-setcookie` on top of an inherited one gives the peer TWO arity-1
  # `-setcookie` options, and OTP's `auth:init_cookie/0` treats any combination
  # other than exactly one as if none were given — silently falling back to
  # `$HOME/.erlang.cookie`. That is worse than a broken handshake: it hands the
  # peer the host's REAL cluster cookie, defeating the throwaway-cookie
  # isolation this file must be runnable under on a box that also runs a live
  # node (see the moduledoc). So when the environment already carries one, let
  # the peer inherit it instead of duplicating it.
  defp cookie_args do
    if cookie_in_env?() do
      []
    else
      case Node.get_cookie() do
        :nocookie -> []
        cookie -> [~c"-setcookie", Atom.to_charlist(cookie)]
      end
    end
  end

  defp cookie_in_env? do
    Enum.any?(~w(ERL_AFLAGS ERL_FLAGS ERL_ZFLAGS), fn var ->
      String.contains?(System.get_env(var) || "", "-setcookie")
    end)
  end

  defp remote_md5(node, mod) do
    :erpc.call(node, :erlang, :get_module_info, [mod, :md5], 5_000)
  catch
    _, _ -> :missing
  end

  # Any OTP installation on this box whose ERTS differs from ours.
  defp alt_erl do
    local = CodeSync.local_erts_version()

    @erlang_install_glob
    |> Path.expand()
    |> Path.wildcard()
    |> Enum.find(fn erl ->
      case erts_of(erl) do
        nil -> false
        version -> version != local
      end
    end)
  end

  defp erts_of(erl) do
    case System.cmd(
           erl,
           ["-noshell", "-eval", ~s{io:format("~s",[erlang:system_info(version)]),halt().}],
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # -------------------------------------------------------------------
  # Same-ERTS peer: the happy paths, for real, over the wire
  # -------------------------------------------------------------------

  describe "pushing to a matching peer" do
    setup do
      {:ok, peer} = start_peer(%{})
      %{peer: peer}
    end

    test "the peer is ERTS-compatible with us", %{peer: peer} do
      assert CodeSync.compatible?(peer) == :ok
    end

    test "a module the peer has never seen is reported missing, then loaded, then identical",
         %{peer: peer} do
      mod = unique_subject_name()
      cleanup_subject(mod)
      entry = compile_subject(mod, 1)

      assert {:ok, %{missing: [^mod], drifted: [], identical: []}} =
               CodeSync.drift([entry], peer)

      assert {:ok, report} = CodeSync.push([entry], peer)
      assert report.loaded == [mod]
      assert report.wedged == []
      assert report.errors == []

      # It genuinely runs there now.
      assert :erpc.call(peer, mod, :version, [], 5_000) == 1

      assert {:ok, %{missing: [], drifted: [], identical: [^mod]}} = CodeSync.drift([entry], peer)

      # And a second push is a no-op rather than a wasted code generation.
      assert {:ok, %{loaded: [], skipped_identical: [^mod]}} = CodeSync.push([entry], peer)
    end

    test "a changed module is reported as drifted and replaced", %{peer: peer} do
      mod = unique_subject_name()
      cleanup_subject(mod)

      v2 = compile_subject(mod, 2)
      v1 = compile_subject(mod, 1)
      :code.soft_purge(mod)

      assert {:ok, %{loaded: [^mod]}} = CodeSync.push([v1], peer)
      assert :erpc.call(peer, mod, :version, [], 5_000) == 1

      assert {:ok, %{drifted: [^mod]}} = CodeSync.drift([v2], peer)
      assert {:ok, %{loaded: [^mod]}} = CodeSync.push([v2], peer)
      assert :erpc.call(peer, mod, :version, [], 5_000) == 2
    end

    test "REFUSES a module whose old code is still in use ON THE PEER, and kills nothing there",
         %{peer: peer} do
      mod = unique_subject_name()
      cleanup_subject(mod)

      v2 = compile_subject(mod, 2)
      v1 = compile_subject(mod, 1)
      :code.soft_purge(mod)

      assert {:ok, %{loaded: [^mod]}} = CodeSync.push([v1], peer)

      # Park a remote process inside the module's code...
      parked = Node.spawn(peer, mod, :loop, [])
      send(parked, {:ping, self()})
      assert_receive {:pong, 1}, 5_000

      # ...then make that generation OLD on the peer.
      {:module, ^mod} =
        :erpc.call(peer, :code, :load_binary, [mod, v1.path, v1.binary], 5_000)

      refute :erpc.call(peer, :code, :soft_purge, [mod], 5_000)

      assert {:ok, report} = CodeSync.push([v2], peer)
      assert report.wedged == [mod]
      assert report.loaded == []
      assert report.errors == []

      # Nothing was forced, so nothing died, and the peer still runs v1.
      # (:erlang, not Process — the peer is a bare Erlang node with no
      # Elixir on its code path.)
      assert :erpc.call(peer, :erlang, :is_process_alive, [parked], 5_000)
      send(parked, {:ping, self()})
      assert_receive {:pong, 1}, 5_000
      assert :erpc.call(peer, mod, :version, [], 5_000) == 1

      send(parked, :stop)
    end

    test "push_dir/3 ships a real ebin directory to the peer", %{peer: peer} do
      dir =
        Path.join(System.tmp_dir!(), "code_sync_push_dir_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      for module <- [OrcaHub.Cluster.CodeSync, OrcaHub.BuildInfo] do
        File.cp!(
          Path.join(CodeSync.default_ebin_dir(), "#{module}.beam"),
          Path.join(dir, "#{module}.beam")
        )
      end

      result = CodeSync.push_dir(dir, [peer])

      assert result.nodes_updated == 1
      assert result.errors == []
      assert OrcaHub.Cluster.CodeSync in result.modules

      # BuildInfo must never ride along — /api/version on the peer would
      # start reporting THIS machine's git SHA.
      refute OrcaHub.BuildInfo in result.modules
      assert remote_md5(peer, OrcaHub.BuildInfo) == :missing

      assert remote_md5(peer, OrcaHub.Cluster.CodeSync) ==
               :erlang.get_module_info(OrcaHub.Cluster.CodeSync, :md5)
    end
  end

  # -------------------------------------------------------------------
  # Cross-ERTS peer: the gate, against two real runtimes
  # -------------------------------------------------------------------

  describe "pushing to a peer on a different ERTS" do
    setup do
      case alt_erl() do
        nil ->
          {:ok, skip: "no second OTP installation found under #{@erlang_install_glob}"}

        erl ->
          case start_peer(%{exec: {to_charlist(erl), []}}) do
            {:ok, peer} -> {:ok, peer: peer, alt_erl: erl}
            other -> {:ok, skip: "could not start a peer from #{erl}: #{inspect(other)}"}
          end
      end
    end

    test "compatible?/1 reports the real mismatch, naming both runtimes", context do
      if context[:skip] do
        IO.puts("\n  SKIPPED (#{context.skip})")
      else
        peer = context.peer
        local = CodeSync.local_erts_version()
        remote = to_string(:erpc.call(peer, :erlang, :system_info, [:version], 5_000))

        refute local == remote

        assert CodeSync.compatible?(peer) == {:error, {:erts_mismatch, local, remote}}

        message = CodeSync.describe_error({:erts_mismatch, local, remote})
        assert message =~ local
        assert message =~ remote
      end
    end

    test "push/3 REFUSES by default and loads absolutely nothing", context do
      if context[:skip] do
        IO.puts("\n  SKIPPED (#{context.skip})")
      else
        peer = context.peer
        mod = unique_subject_name()
        cleanup_subject(mod)
        entry = compile_subject(mod, 1)

        assert remote_md5(peer, mod) == :missing

        assert {:error, {:erts_mismatch, _local, _remote}} = CodeSync.push([entry], peer)

        # The refusal is total: not one module of the payload landed.
        assert remote_md5(peer, mod) == :missing
      end
    end

    test "allow_erts_mismatch: true is the deliberate override", context do
      if context[:skip] do
        IO.puts("\n  SKIPPED (#{context.skip})")
      else
        peer = context.peer
        mod = unique_subject_name()
        cleanup_subject(mod)
        entry = compile_subject(mod, 1)

        assert {:ok, %{loaded: [^mod]}} = CodeSync.push([entry], peer, allow_erts_mismatch: true)
        assert remote_md5(peer, mod) == entry.md5
      end
    end

    test "the fan-out wrapper surfaces the refusal as one operator-readable line", context do
      if context[:skip] do
        IO.puts("\n  SKIPPED (#{context.skip})")
      else
        peer = context.peer

        result = CodeSync.push_dir(CodeSync.default_ebin_dir(), [peer])

        assert result.nodes_updated == 0
        assert result.modules_pushed == 0
        assert [message] = result.errors
        assert message =~ to_string(peer)
        assert message =~ "ERTS mismatch"
        assert message =~ CodeSync.local_erts_version()
      end
    end
  end
end
