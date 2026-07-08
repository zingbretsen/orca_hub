defmodule OrcaHub.MCP.CodeExec.PlaywrightUpload do
  @moduledoc """
  Rewrites LOCAL (OrcaHub-node) file paths in playwright-mcp's `paths` arg into
  pod-side paths, by pushing the bytes to an upload sidecar deployed alongside
  playwright-mcp in its k8s pod.

  `browser_file_upload` and `browser_drop` take a `paths` arg that playwright
  reads from ITS OWN pod's filesystem — a path to a file on this node is
  unreachable to it. The sidecar accepts a raw-body `POST
  <base>/upload/<subdir>/<filename>` and returns `{"path": "/uploads/..."}`,
  a path playwright can actually read.

  `maybe_rewrite_paths/4` is the public seam `Dispatcher.dispatch/3` calls: it
  inspects `args["paths"]`, uploads any entry that's an existing local file
  (`File.regular?/1`), and leaves everything else — already pod-side paths
  from a prior call, or references only meaningful inside playwright's own
  pod — completely untouched. `upload_fun` is injectable so tests can exercise
  the rewrite logic without a live sidecar.
  """

  alias OrcaHub.MCP.CodeExec.MediaSink

  @max_upload_bytes 32 * 1024 * 1024
  @upload_paths_tools ["browser_file_upload", "browser_drop"]

  @doc """
  If `name` (matched by suffix, same style as `Dispatcher`'s filename-trap
  tools) is one of `browser_file_upload`/`browser_drop` and `args["paths"]` is
  a list, upload every entry that's an existing local file and replace it
  with the pod-side path the sidecar returns; every other entry (not an
  existing local file — already pod-side, or made up) passes through
  unchanged and is never handed to `upload_fun`.

  Returns `{:ok, args}` (untouched when `name` doesn't match or there's no
  `paths` list) or `{:error, envelope}` — an MCP error envelope
  (`%{"isError" => true, "content" => [...]}`) ready to return directly from
  `Dispatcher.dispatch/3` — on the first upload failure. Processing stops at
  the first failure; no attempt is made to upload remaining entries.

  `upload_fun` is `(path, subdir, filename -> {:ok, pod_path} | {:error,
  reason})`, defaulting to the real sidecar-backed implementation.
  """
  def maybe_rewrite_paths(name, args, session_id, upload_fun \\ &default_upload/3)

  def maybe_rewrite_paths(name, %{"paths" => paths} = args, session_id, upload_fun)
      when is_list(paths) do
    if suffix_match?(name) do
      subdir = subdir_for(session_id)

      case rewrite_paths(paths, subdir, upload_fun) do
        {:ok, rewritten} -> {:ok, Map.put(args, "paths", rewritten)}
        {:error, envelope} -> {:error, envelope}
      end
    else
      {:ok, args}
    end
  end

  def maybe_rewrite_paths(_name, args, _session_id, _upload_fun), do: {:ok, args}

  defp suffix_match?(name), do: Enum.any?(@upload_paths_tools, &String.ends_with?(name, &1))

  defp subdir_for(id) when is_binary(id),
    do: MediaSink.safe_dir_segment(MediaSink.sanitize_for_filename(id))

  defp subdir_for(_id), do: "shared"

  defp rewrite_paths(paths, subdir, upload_fun) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case rewrite_one(path, subdir, upload_fun) do
        {:ok, rewritten} -> {:cont, {:ok, [rewritten | acc]}}
        {:error, envelope} -> {:halt, {:error, envelope}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, envelope} -> {:error, envelope}
    end
  end

  defp rewrite_one(path, subdir, upload_fun) when is_binary(path) do
    if File.regular?(path) do
      upload_local_file(path, subdir, upload_fun)
    else
      {:ok, path}
    end
  end

  defp rewrite_one(path, _subdir, _upload_fun), do: {:ok, path}

  defp upload_local_file(path, subdir, upload_fun) do
    size = File.stat!(path).size

    if size > @max_upload_bytes do
      {:error,
       error_envelope(
         "refusing to upload #{path}: file is #{size} bytes, over the #{@max_upload_bytes}-byte (32MB) cap"
       )}
    else
      filename = filename_for(path)

      case upload_fun.(path, subdir, filename) do
        {:ok, pod_path} -> {:ok, pod_path}
        {:error, reason} -> {:error, error_envelope("failed to upload #{path}: #{reason}")}
      end
    end
  end

  defp filename_for(path) do
    case MediaSink.sanitize_for_filename(Path.basename(path)) do
      seg when seg in ["", ".", ".."] -> "upload"
      seg -> seg
    end
  end

  defp error_envelope(message) do
    %{"isError" => true, "content" => [%{"type" => "text", "text" => message}]}
  end

  defp default_upload(path, subdir, filename) do
    base_url = Application.get_env(:orca_hub, :playwright_upload_url)
    url = "#{base_url}/upload/#{URI.encode(subdir)}/#{URI.encode(filename)}"

    case File.read(path) do
      {:ok, body} -> post_upload(url, body)
      {:error, reason} -> {:error, "could not read local file: #{inspect(reason)}"}
    end
  end

  defp post_upload(url, body) do
    case Req.post(url: url, body: body, receive_timeout: 30_000) do
      {:ok, %Req.Response{status: 200, body: %{"path" => pod_path}}} ->
        {:ok, pod_path}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        {:error, "upstream sidecar returned status #{status}: #{inspect(resp_body)}"}

      {:error, exception} ->
        {:error, "request to upload sidecar failed: #{Exception.message(exception)}"}
    end
  end
end
