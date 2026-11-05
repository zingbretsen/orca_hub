defmodule OrcaHubWeb.LazyChunkCacheTest do
  @moduledoc """
  The lazy bundles' chunks (`priv/static/assets/js/lazy/chunks/`) are served
  immutable by their own `Plug.Static` in the endpoint: esbuild content-hashes
  every chunk name, and they are reached by relative import, never with the
  `?vsn=` query that gives the entry files a long cache. Everything else keeps
  Plug.Static's default ETag revalidation.

  The files are build output (gitignored), so each test writes its own
  uniquely named file under priv/static and removes it again.
  """

  use OrcaHubWeb.ConnCase, async: true

  @static Application.app_dir(:orca_hub, "priv/static")
  @immutable "public, max-age=31536000, immutable"

  setup do
    tag = System.unique_integer([:positive])
    lazy = Path.join(@static, "assets/js/lazy")
    chunks = Path.join(lazy, "chunks")
    new_dirs = Enum.reject([lazy, chunks], &File.dir?/1)
    File.mkdir_p!(chunks)

    chunk = Path.join(chunks, "chunk-TEST#{tag}.js")
    entry = Path.join(lazy, "entry-test#{tag}.js")
    File.write!(chunk, "export const x = #{tag}\n")
    File.write!(entry, "import './chunks/chunk-TEST#{tag}.js'\n")

    on_exit(fn ->
      File.rm(chunk)
      File.rm(entry)
      # Only directories this test created, and only if nothing else is in them.
      for dir <- Enum.reverse(new_dirs), do: File.rmdir(dir)
    end)

    %{
      chunk_path: "/assets/js/lazy/chunks/chunk-TEST#{tag}.js",
      entry_path: "/assets/js/lazy/entry-test#{tag}.js",
      tag: tag
    }
  end

  test "a lazy chunk is served immutable", %{conn: conn, chunk_path: path, tag: tag} do
    conn = get(conn, path)

    assert conn.status == 200
    assert conn.resp_body == "export const x = #{tag}\n"
    assert get_resp_header(conn, "cache-control") == [@immutable]
    assert ["text/javascript" <> _] = get_resp_header(conn, "content-type")
  end

  test "an entry file without ?vsn= keeps ETag revalidation", %{conn: conn, entry_path: path} do
    conn = get(conn, path)

    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["public"]
    assert [_etag] = get_resp_header(conn, "etag")
  end

  test "an entry file with ?vsn= (its digested URL in prod) is immutable too", %{
    conn: conn,
    entry_path: path
  } do
    conn = get(conn, path <> "?vsn=d")

    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == [@immutable]
  end

  test "a missing chunk falls through to a 404", %{conn: conn, tag: tag} do
    conn = get(conn, "/assets/js/lazy/chunks/chunk-MISSING#{tag}.js")

    assert conn.status == 404
  end
end
