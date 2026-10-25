defmodule OrcaHubWeb.FileDownloadControllerDistributedTest do
  @moduledoc """
  ORCAHUB3-148: `GET /sessions/:id/files/image` stats the file on the
  session's owning node through `stat_image/3`, an export that only exists
  from ORCAHUB3-148 on. During a rolling deploy that node can still be on
  older code, and every image in its sessions' feeds must keep loading
  rather than 503. Needs a real second node, so it's split out and tagged
  `:distributed` like cluster_distributed_test.exs (`Node.start/1` and
  `:peer` are process-wide state that would race the async suite).
  """
  use OrcaHubWeb.ConnCase, async: false

  @moduletag :distributed

  alias OrcaHub.Sessions

  # The pre-ORCAHUB3-148 remote surface, `stat_confined/3` and
  # `read_chunk/3` with no `stat_image/3`, as Erlang so a bare peer (no
  # Elixir on its code path) can load it. No confinement: only the hub-side
  # fallback is under test here.
  @old_controller ~S"""
  -module('Elixir.OrcaHubWeb.FileDownloadController').
  -export([stat_confined/3, read_chunk/3]).

  stat_confined(Root, Path, _MaxBytes) ->
      Resolved = filename:join(Root, Path),
      {ok, Info} = file:read_file_info(Resolved),
      {ok, Resolved, element(2, Info)}.

  read_chunk(Path, Offset, Size) ->
      {ok, File} = file:open(Path, [read, binary]),
      Result = case file:pread(File, Offset, Size) of
          {ok, Data} -> {ok, Data};
          eof -> {ok, <<>>}
      end,
      file:close(File),
      Result.
  """

  setup do
    # ClusterNodeTracker writes to the DB from its own process whenever a
    # real :nodeup fires — pause it, same as cluster_distributed_test.exs.
    Supervisor.terminate_child(OrcaHub.Supervisor, OrcaHub.ClusterNodeTracker)
    on_exit(fn -> Supervisor.restart_child(OrcaHub.Supervisor, OrcaHub.ClusterNodeTracker) end)

    unless Node.alive?() do
      {:ok, hostname} = :inet.gethostname()
      {:ok, _pid} = Node.start(:"file_image_test@#{hostname}", :shortnames)
    end

    {:ok, peer_pid, peer_node} =
      :peer.start_link(%{name: :"file_image_old_peer_#{System.unique_integer([:positive])}"})

    on_exit(fn ->
      try do
        :peer.stop(peer_pid)
      catch
        :exit, _ -> :ok
      end
    end)

    dir = Path.join(System.tmp_dir!(), "file_image_dist_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".orca_uploads"))
    on_exit(fn -> File.rm_rf(dir) end)

    photo = <<0xFF, 0xD8, 0xFF, 0xE0>> <> :crypto.strong_rand_bytes(2048)
    File.write!(Path.join([dir, ".orca_uploads", "upload_1.jpg"]), photo)

    {:ok, session} =
      Sessions.create_session(%{directory: dir, runner_node: Atom.to_string(peer_node)})

    {:ok, peer_node: peer_node, session: session, photo: photo}
  end

  test "ORCAHUB3-148: a node without stat_image/3 still serves the image, just without an ETag",
       %{conn: conn, peer_node: peer_node, session: session, photo: photo} do
    load_old_controller!(peer_node)

    conn =
      get(conn, ~p"/sessions/#{session.id}/files/image?#{[path: ".orca_uploads/upload_1.jpg"]}")

    assert conn.status == 200
    assert conn.resp_body == photo
    assert get_resp_header(conn, "etag") == []
    assert ["private, max-age=" <> _] = get_resp_header(conn, "cache-control")
    assert get_resp_header(conn, "content-security-policy") == ["sandbox"]
  end

  test "ORCAHUB3-148: a node with no file-serving code at all is a 503, not a crash",
       %{conn: conn, session: session} do
    conn =
      get(conn, ~p"/sessions/#{session.id}/files/image?#{[path: ".orca_uploads/upload_1.jpg"]}")

    assert conn.status == 503
  end

  defp load_old_controller!(peer_node) do
    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(@old_controller))

    forms =
      tokens
      |> Enum.chunk_while(
        [],
        fn
          {:dot, _} = dot, acc -> {:cont, Enum.reverse([dot | acc]), []}
          token, acc -> {:cont, [token | acc]}
        end,
        fn acc -> {:cont, acc} end
      )
      |> Enum.reject(&(&1 == []))
      |> Enum.map(fn form_tokens ->
        {:ok, form} = :erl_parse.parse_form(form_tokens)
        form
      end)

    {:ok, module, binary} = :compile.forms(forms, [:binary])

    {:module, ^module} =
      :erpc.call(peer_node, :code, :load_binary, [module, ~c"old.beam", binary])

    refute :erpc.call(peer_node, :erlang, :function_exported, [module, :stat_image, 3])
  end
end
