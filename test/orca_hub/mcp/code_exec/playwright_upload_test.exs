defmodule OrcaHub.MCP.CodeExec.PlaywrightUploadTest do
  use ExUnit.Case, async: true

  alias OrcaHub.MCP.CodeExec.PlaywrightUpload

  setup do
    dir =
      Path.join(System.tmp_dir!(), "playwright_upload_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "maybe_rewrite_paths/4 local-file rewrite" do
    test "an existing local file is uploaded and replaced with the stub's pod-side path", %{
      dir: dir
    } do
      local_path = Path.join(dir, "shot.png")
      File.write!(local_path, "fake-bytes")

      upload_fun = fn path, subdir, filename ->
        send(self(), {:uploaded, path, subdir, filename})
        {:ok, "/uploads/#{subdir}/#{filename}"}
      end

      args = %{"paths" => [local_path, "/uploads/foo/bar.png"]}

      assert {:ok, rewritten} =
               PlaywrightUpload.maybe_rewrite_paths(
                 "playwright__browser_file_upload",
                 args,
                 "sess-1",
                 upload_fun
               )

      assert rewritten == %{"paths" => ["/uploads/sess-1/shot.png", "/uploads/foo/bar.png"]}
      assert_received {:uploaded, ^local_path, "sess-1", "shot.png"}
    end
  end

  describe "maybe_rewrite_paths/4 pass-through" do
    test "an entry that isn't an existing local file is left unchanged and never uploaded" do
      upload_fun = fn _path, _subdir, _filename ->
        flunk("upload_fun should not be called for a non-local-file entry")
      end

      nonexistent = "/uploads/foo/bar.png"
      args = %{"paths" => [nonexistent]}

      assert {:ok, %{"paths" => [^nonexistent]}} =
               PlaywrightUpload.maybe_rewrite_paths(
                 "playwright__browser_drop",
                 args,
                 "sess-1",
                 upload_fun
               )
    end
  end

  describe "maybe_rewrite_paths/4 error envelope on upload failure" do
    test "stub error stops processing and returns an error envelope mentioning the path", %{
      dir: dir
    } do
      local_path = Path.join(dir, "shot.png")
      File.write!(local_path, "fake-bytes")

      upload_fun = fn _path, _subdir, _filename -> {:error, "connection refused"} end

      args = %{"paths" => [local_path]}

      assert {:error, envelope} =
               PlaywrightUpload.maybe_rewrite_paths(
                 "playwright__browser_file_upload",
                 args,
                 "sess-1",
                 upload_fun
               )

      assert %{"isError" => true, "content" => [%{"type" => "text", "text" => message}]} =
               envelope

      assert message =~ local_path
      assert message =~ "connection refused"
    end
  end

  describe "maybe_rewrite_paths/4 error envelope on oversize file" do
    test "a file over the 32MB cap is refused without calling upload_fun", %{dir: dir} do
      oversize_path = Path.join(dir, "big.bin")
      # 32MB + 1 byte, written sparsely-ish via a single big binary is fine for
      # a one-off test; on_exit at describe-block setup already cleans `dir`.
      File.write!(oversize_path, :binary.copy(<<0>>, 32 * 1024 * 1024 + 1))

      upload_fun = fn _path, _subdir, _filename ->
        flunk("upload_fun should not be called for an oversize file")
      end

      args = %{"paths" => [oversize_path]}

      assert {:error, envelope} =
               PlaywrightUpload.maybe_rewrite_paths(
                 "playwright__browser_file_upload",
                 args,
                 "sess-1",
                 upload_fun
               )

      assert %{"isError" => true, "content" => [%{"type" => "text", "text" => message}]} =
               envelope

      assert message =~ oversize_path
    end
  end

  describe "maybe_rewrite_paths/4 non-matching tool name" do
    test "a tool name that doesn't match the suffix passes args through unchanged, no upload attempted" do
      upload_fun = fn _path, _subdir, _filename ->
        flunk("upload_fun should not be called for a non-matching tool")
      end

      args = %{"paths" => ["/some/local/path"]}

      assert {:ok, ^args} =
               PlaywrightUpload.maybe_rewrite_paths(
                 "playwright__browser_navigate",
                 args,
                 "sess-1",
                 upload_fun
               )
    end
  end

  describe "maybe_rewrite_paths/4 with no paths key" do
    test "a matching tool name with no paths key at all passes through unchanged, no crash" do
      upload_fun = fn _path, _subdir, _filename ->
        flunk("upload_fun should not be called when there's no paths key")
      end

      args = %{"other" => "value"}

      assert {:ok, ^args} =
               PlaywrightUpload.maybe_rewrite_paths(
                 "playwright__browser_file_upload",
                 args,
                 "sess-1",
                 upload_fun
               )
    end
  end
end
