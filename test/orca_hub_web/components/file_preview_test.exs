defmodule OrcaHubWeb.FilePreviewTest do
  use ExUnit.Case, async: true

  alias OrcaHubWeb.FilePreview

  describe "media_kind/1" do
    test "browser-renderable images and videos, case-insensitively" do
      for path <- ~w(a.png b.JPG c.jpeg d.gif e.webp f.avif g.svg h.bmp i.ico dir/j.PNG) do
        assert FilePreview.media_kind(path) == :image, path
      end

      for path <- ~w(a.mp4 b.webm c.ogv d.mov E.MP4) do
        assert FilePreview.media_kind(path) == :video, path
      end
    end

    test "everything else is nil: PDFs, formats browsers can't show, text, no extension" do
      for path <- ~w(a.pdf b.tiff c.heic d.avi e.mkv f.html g.txt h.zip Makefile .env) do
        assert FilePreview.media_kind(path) == nil, path
      end

      assert FilePreview.media_kind(nil) == nil
    end
  end

  test "inline_type?/1 agrees with media_kind/1 and refuses text/html" do
    assert FilePreview.inline_type?("image/svg+xml")
    assert FilePreview.inline_type?("video/mp4")
    refute FilePreview.inline_type?("text/html")
    refute FilePreview.inline_type?("application/pdf")
  end

  test "inline_url/3 adds disposition and the version, query-encoded" do
    assert FilePreview.inline_url("/sessions/s1/files/download", "a dir/x&y.png", "42") ==
             "/sessions/s1/files/download?path=a+dir%2Fx%26y.png&disposition=inline&v=42"

    assert FilePreview.inline_url("/b", "x.png", nil) == "/b?path=x.png&disposition=inline"
  end

  test "version/1 turns a File.stat mtime into a token, and anything else into nil" do
    assert FilePreview.version({{2026, 10, 3}, {12, 0, 0}}) == "63958248000"
    assert FilePreview.version({{2026, 10, 3}, {12, 0, 1}}) == "63958248001"
    assert FilePreview.version(nil) == nil
  end
end
