defmodule OrcaHub.Files do
  @moduledoc """
  Hub-only context for the cross-node file store (ORCAHUB3-72): Postgres
  metadata here, bytes in `OrcaHub.ObjectStore`. Lets sessions on different
  nodes exchange files (agents are not meshed; `Cluster.rpc` relays via the
  hub) without hand-writing base64, and gives a session a way to get a
  local file into Elixir-side features without the `run_elixir` sandbox
  ever holding `File`.

  Called only via `OrcaHub.HubRPC` from `OrcaHub.MCP.Tools.Files` (which
  runs in the BEAM on the session's OWN runner node, outside the sandbox,
  and does the actual disk I/O for `put_file`/`get_file` locally before/
  after shipping bytes through here) — never directly from agent-node code.

  ## Security invariants (each has a negative test)

  1. `put_file`'s source path is confined to the calling session's
     directory by REALPATH (`OrcaHub.PathConfinement`) at the MCP-tool
     layer, before any bytes reach this module — symlink escapes, `..`,
     and absolute paths outside the directory are all refused there.
  2. `get_file` never accepts a destination path from the caller; the MCP
     tool layer always writes under the caller's own session directory,
     `.orca_inbox/<8-char id prefix>_<basename of stored name>`.
  3. Size cap `@max_file_bytes` (50MB, matches the UI upload cap) per file,
     plus a per-project quota (`project_quota_bytes/0`, 2GB default,
     `ORCA_FILE_STORE_PROJECT_QUOTA_BYTES`-overridable) enforced in
     `create_file/2` before any bytes are written.
  4. Visibility (`visible?/3`, `list_visible/1`): a file is visible to any
     session in its OWN project, to its creating session, and to any
     session/project it was explicitly shared with (`file_shares`).
     `share_file/2` to a session on another node is gated by
     `OrcaHub.NodePolicy.cross_node_allowed?/1` at the MCP-tool layer
     (checked on the CALLING session's own node, since that's what
     isolation is about — never re-checked here on the hub).
  5. Object store credentials (S3 access/secret keys) are read only by
     `OrcaHub.ObjectStore` on the hub; an agent node never holds them —
     enforced structurally by this module always running hub-side.
  6. `.orca_inbox/` is in `OrcaHub.GlobalGitignore.patterns/0`.

  `delete_file/1`'s authorization (creator or same project only — no
  transitive delete via a share) is `deletable?/3`, deliberately narrower
  than `visible?/3`.
  """

  import Ecto.Query

  alias OrcaHub.Files.{File, FileShare}
  alias OrcaHub.ObjectStore
  alias OrcaHub.Repo

  @max_file_bytes 50 * 1024 * 1024
  @default_project_quota_bytes 2 * 1024 * 1024 * 1024

  @doc "Per-file size cap in bytes (50MB, matches the UI upload cap)."
  def max_file_bytes, do: @max_file_bytes

  @doc "Per-project quota in bytes (env-overridable, default 2GB)."
  def project_quota_bytes do
    Application.get_env(
      :orca_hub,
      :file_store_project_quota_bytes,
      @default_project_quota_bytes
    )
  end

  @doc """
  Stores `binary` and creates its metadata row. `attrs` is an atom-keyed map
  with `:name`, optional `:content_type`, `:project_id`, `:session_id`.
  Bytes are written to the object store BEFORE the DB row is inserted (so a
  failed insert never leaves a row pointing at missing bytes — the reverse
  ordering could); if the insert then fails, the just-written object is
  cleaned up. Returns `{:ok, file}`, `{:error, :too_large}`,
  `{:error, :quota_exceeded}`, or `{:error, changeset}`.
  """
  def create_file(attrs, binary) when is_binary(binary) do
    size = byte_size(binary)
    project_id = Map.get(attrs, :project_id)

    with :ok <- check_size(size),
         :ok <- check_quota(project_id, size) do
      file_id = Ecto.UUID.generate()
      sha256 = binary |> :crypto.hash(:sha256) |> Base.encode16(case: :lower)
      object_key = build_object_key(project_id, file_id, Map.get(attrs, :name))

      case ObjectStore.put(object_key, binary, Map.get(attrs, :content_type)) do
        :ok ->
          insert_attrs =
            attrs
            |> Map.merge(%{size_bytes: size, sha256: sha256, object_key: object_key})

          %File{id: file_id}
          |> File.changeset(insert_attrs)
          |> Repo.insert()
          |> case do
            {:ok, file} ->
              {:ok, file}

            {:error, changeset} ->
              ObjectStore.delete(object_key)
              {:error, changeset}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp check_size(size) when size > @max_file_bytes, do: {:error, :too_large}
  defp check_size(_size), do: :ok

  defp check_quota(nil, _additional), do: :ok

  defp check_quota(project_id, additional) do
    used =
      File
      |> where([f], f.project_id == ^project_id)
      |> select([f], sum(f.size_bytes))
      |> Repo.one()
      |> Kernel.||(0)

    if used + additional > project_quota_bytes() do
      {:error, :quota_exceeded}
    else
      :ok
    end
  end

  defp build_object_key(project_id, file_id, name) do
    scope = project_id || "unscoped"
    sanitized = sanitize_name(name)
    "#{scope}/#{file_id}/#{sanitized}"
  end

  defp sanitize_name(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
  end

  @doc "Raw fetch by id, no visibility check. `nil` if not found."
  def get_file(id), do: Repo.get(File, id)

  @doc """
  Visibility check (invariant 4): creator, same project, or explicitly
  shared with the caller's session or project.
  """
  def visible?(%File{} = file, caller_session_id, caller_project_id) do
    file.session_id == caller_session_id ||
      (not is_nil(file.project_id) and file.project_id == caller_project_id) ||
      Repo.exists?(
        from s in FileShare,
          where:
            s.file_id == ^file.id and
              ((not is_nil(^caller_session_id) and s.session_id == ^caller_session_id) or
                 (not is_nil(^caller_project_id) and s.project_id == ^caller_project_id))
      )
  end

  @doc """
  Narrower than `visible?/3`: only the creating session or a session in the
  same project may delete — an explicit share never grants delete rights.
  """
  def deletable?(%File{} = file, caller_session_id, caller_project_id) do
    file.session_id == caller_session_id ||
      (not is_nil(file.project_id) and file.project_id == caller_project_id)
  end

  @doc """
  Fetches `file_id`'s metadata + bytes if visible to the given caller
  context, else `{:error, :not_found}` (deliberately not `:forbidden` — no
  existence oracle for a file the caller can't see).
  """
  def fetch_visible_binary(file_id, %{session_id: session_id, project_id: project_id}) do
    with %File{} = file <- get_file(file_id),
         true <- visible?(file, session_id, project_id),
         {:ok, binary} <- ObjectStore.get(file.object_key) do
      {:ok, file, binary}
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Every file visible to the given caller context — its own uploads, its
  project's files, and anything explicitly shared with it — optionally
  narrowed to one project via `:project_id` in addition to the caller's
  own scope (still subject to the same visibility rule).
  """
  def list_visible(%{session_id: session_id, project_id: project_id} = context) do
    query =
      from f in File,
        left_join: s in FileShare,
        on: s.file_id == f.id,
        where:
          f.session_id == ^session_id or
            (not is_nil(f.project_id) and f.project_id == ^project_id) or
            (not is_nil(^session_id) and s.session_id == ^session_id) or
            (not is_nil(^project_id) and s.project_id == ^project_id),
        distinct: f.id,
        order_by: [desc: f.inserted_at]

    query =
      case Map.get(context, :filter_project_id) do
        nil -> query
        filter_project_id -> where(query, [f], f.project_id == ^filter_project_id)
      end

    Repo.all(query)
  end

  @doc """
  Shares `file` with a session or project (exactly one of the two, see
  `FileShare.changeset/2`). Cross-node authorization for a session target
  is the MCP-tool layer's job (`OrcaHub.NodePolicy.cross_node_allowed?/1`,
  checked on the calling session's own node) — this function only persists
  the grant.
  """
  def share_file(%File{} = file, attrs) do
    %FileShare{}
    |> FileShare.changeset(Map.put(attrs, :file_id, file.id))
    |> Repo.insert()
  end

  @doc "Deletes the metadata row (cascading its shares) and its bytes."
  def delete_file(%File{} = file) do
    case Repo.delete(file) do
      {:ok, deleted} ->
        ObjectStore.delete(deleted.object_key)
        {:ok, deleted}

      error ->
        error
    end
  end
end
