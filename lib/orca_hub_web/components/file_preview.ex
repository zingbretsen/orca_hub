defmodule OrcaHubWeb.FilePreview do
  @moduledoc """
  Image and video previews for working-directory files (ORCAHUB3-77), shared
  by the session file panel (desktop column and mobile modal), the project
  page's file viewer, and `OrcaHubWeb.FileTreeComponent`.

  The allow-list below is the single source of truth for both halves: a
  viewer only offers a preview for a path whose `MIME.from_path/1` type is
  on it, and `OrcaHubWeb.FileDownloadController` only serves that same set
  with `content-disposition: inline` — so a viewer can never point an
  `<img>`/`<video>` at bytes the controller would hand back as an
  attachment. Everything else (PDFs included, for now: the controller's
  `content-security-policy: sandbox` breaks Chrome's PDF viewer) stays
  download-only.

  Formats are limited to what current browsers actually render; TIFF, HEIC,
  AVI and friends would only ever show a broken image or a dead player.
  SVG is on the list: it is served with that same CSP sandbox, so opening
  the inline URL directly can't run its scripts, and an `<img>` never runs
  them anyway.
  """
  use Phoenix.Component

  @image_types ~w(image/png image/jpeg image/gif image/webp image/avif image/apng
                  image/bmp image/vnd.microsoft.icon image/svg+xml)
  @video_types ~w(video/mp4 video/webm video/ogg video/quicktime)

  @doc """
  `:image` or `:video` when a file viewer should preview `path` instead of
  loading it as text, otherwise `nil`.
  """
  def media_kind(path) when is_binary(path) do
    mime = MIME.from_path(path)

    cond do
      mime in @image_types -> :image
      mime in @video_types -> :video
      true -> nil
    end
  end

  def media_kind(_path), do: nil

  @doc "Whether `mime` may be served `inline` by the file download routes."
  def inline_type?(mime), do: mime in @image_types or mime in @video_types

  @doc "The attachment URL for `path` under a `/files/download` route."
  def download_url(base, path), do: "#{base}?#{URI.encode_query(%{"path" => path})}"

  @doc """
  The inline (preview) URL for `path` under a `/files/download` route.
  `version` (see `version/1`) only busts the browser cache: the controller
  ignores it, but a new value makes an overwritten file reload.
  """
  def inline_url(base, path, version) do
    query =
      [{"path", path}, {"disposition", "inline"}] ++
        if(version, do: [{"v", version}], else: [])

    "#{base}?#{URI.encode_query(query)}"
  end

  @doc """
  A cache-busting token from a `File.stat/1` mtime (an Erlang datetime
  tuple, as stored in the session panel's `file_mtimes`), or `nil`.
  """
  def version({{_, _, _}, {_, _, _}} = mtime),
    do: Integer.to_string(:calendar.datetime_to_gregorian_seconds(mtime))

  def version(_mtime), do: nil

  attr :id, :string, required: true
  attr :kind, :atom, required: true, values: [:image, :video]
  attr :src, :string, default: nil, doc: "nil when the file can't be served (outside the root)"
  attr :path, :string, required: true

  @doc """
  The preview element, fitted to its container. Give the container a
  definite height (a flex item with `min-h-0`) so `max-h-full` can bound it.
  """
  def media_preview(assigns) do
    ~H"""
    <div
      :if={is_nil(@src)}
      id={@id}
      class="text-sm text-base-content/60 p-8 text-center"
      data-media-unavailable
    >
      This file is outside the working directory, so it can't be previewed.
    </div>
    <div :if={@src} class="flex h-full min-h-0 w-full items-center justify-center">
      <img
        :if={@kind == :image}
        id={@id}
        src={@src}
        alt={Path.basename(@path)}
        class="max-w-full max-h-full object-contain"
      />
      <video
        :if={@kind == :video}
        id={@id}
        src={@src}
        controls
        playsinline
        preload="metadata"
        class="max-w-full max-h-full"
      />
    </div>
    """
  end
end
