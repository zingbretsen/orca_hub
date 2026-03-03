defmodule OrcaHubWeb.MessageComponents do
  use Phoenix.Component

  import OrcaHubWeb.CoreComponents, only: [icon: 1]

  alias OrcaHubWeb.Markdown

  attr :messages, :list, required: true

  def message_feed(assigns) do
    ~H"""
    <div :for={msg <- @messages}>
      <%= case msg["type"] do %>
        <% "user" -> %>
          <.user_message msg={msg} />
        <% "assistant" -> %>
          <.assistant_message msg={msg} />
        <% "result" -> %>
          <.result_message msg={msg} />
        <% "system" -> %>
          <.system_message msg={msg} />
        <% "cli_error" -> %>
          <.cli_error_message msg={msg} />
        <% type when type in ~w(rate_limit_event) -> %>
          <% # Hide noisy internal events %>
        <% _ -> %>
          <div class="text-xs opacity-40">
            <pre class="whitespace-pre-wrap">{Jason.encode!(msg, pretty: true)}</pre>
          </div>
      <% end %>
    </div>
    """
  end

  attr :msg, :map, required: true

  defp user_message(assigns) do
    content_blocks = get_in(assigns.msg, ["message", "content"]) || []

    # Extract text blocks for the user's prompt display
    text =
      content_blocks
      |> Enum.filter(&(is_map(&1) && &1["type"] == "text"))
      |> Enum.map_join("\n", & &1["text"])

    # Extract tool_result blocks
    tool_results =
      content_blocks
      |> Enum.filter(&(is_map(&1) && &1["type"] == "tool_result"))

    # Also check for tool_use_result at top level (alternate format)
    tool_use_result = assigns.msg["tool_use_result"]

    assigns =
      assigns
      |> assign(:text, text)
      |> assign(:tool_results, tool_results)
      |> assign(:tool_use_result, tool_use_result)

    # Extract attachments from text
    {display_text, attachments} = extract_attachments(text)

    assigns =
      assigns
      |> assign(:text, display_text)
      |> assign(:attachments, attachments)

    ~H"""
    <div :if={@text != "" || @attachments != []} class="chat chat-end">
      <div class="chat-header text-xs opacity-50 mb-1">You <.timestamp value={@msg["timestamp"]} /></div>
      <div class="chat-bubble chat-bubble-primary">
        <div :for={{type, path} <- @attachments} class="mb-2">
          <img :if={type == :image} src={image_data_uri(path)} class="max-w-xs max-h-48 rounded" />
          <div :if={type == :file} class="flex items-center gap-2 text-xs opacity-80 bg-primary-content/10 rounded px-2 py-1">
            <.icon name="hero-paper-clip-micro" class="size-3" />
            {Path.basename(path)}
          </div>
        </div>
        <span :if={@text != ""}>{@text}</span>
      </div>
    </div>
    <div :for={tr <- @tool_results} class="ml-4 my-1">
      <.tool_result_block result={tr} />
    </div>
    <div :if={@tool_use_result} class="ml-4 my-1">
      <.tool_result_block result={@tool_use_result} />
    </div>
    """
  end

  attr :msg, :map, required: true

  defp assistant_message(assigns) do
    content_blocks = get_in(assigns.msg, ["message", "content"]) || []

    text_blocks =
      content_blocks
      |> Enum.filter(&(is_map(&1) && &1["type"] == "text"))

    tool_use_blocks =
      content_blocks
      |> Enum.filter(&(is_map(&1) && &1["type"] == "tool_use"))

    text = Enum.map_join(text_blocks, "\n", & &1["text"])

    assigns =
      assigns
      |> assign(:html, Markdown.render(text))
      |> assign(:has_text, text != "")
      |> assign(:tool_uses, tool_use_blocks)
      |> assign(:msg_id, assigns.msg["id"] || System.unique_integer([:positive]))

    ~H"""
    <div :if={@has_text} class="chat chat-start" data-tts-container>
      <div class="chat-header text-xs opacity-50 mb-1">
        <.icon name="hero-sparkles-micro" class="size-3" /> Assistant <.timestamp value={@msg["timestamp"]} />
      </div>
      <div class="chat-bubble prose prose-sm prose-invert max-w-none" data-tts-text>
        {@html}
      </div>
      <div class="chat-footer mt-1" id={"tts-#{@msg_id}"} phx-hook="TTSPlayer" phx-update="ignore">
        <div class="flex items-center gap-1">
          <button data-tts-action="toggle" class="btn btn-ghost btn-xs btn-circle" title="Read aloud">
            <svg xmlns="http://www.w3.org/2000/svg" class="size-4" viewBox="0 0 20 20" fill="currentColor">
              <path d="M6.3 2.84A1.5 1.5 0 004 4.11v11.78a1.5 1.5 0 002.3 1.27l9.344-5.891a1.5 1.5 0 000-2.538L6.3 2.84z"/>
            </svg>
          </button>
          <div data-tts-controls class="hidden flex items-center gap-1">
            <button data-tts-action="prev" class="btn btn-ghost btn-xs btn-circle" title="Previous">
              <.icon name="hero-backward-micro" class="size-3" />
            </button>
            <span data-tts-counter class="text-xs opacity-60 tabular-nums min-w-[3ch] text-center"></span>
            <button data-tts-action="next" class="btn btn-ghost btn-xs btn-circle" title="Next">
              <.icon name="hero-forward-micro" class="size-3" />
            </button>
            <button data-tts-action="stop" class="btn btn-ghost btn-xs btn-circle" title="Stop">
              <.icon name="hero-stop-micro" class="size-3" />
            </button>
          </div>
        </div>
      </div>
    </div>
    <div :for={tool <- @tool_uses}>
      <.tool_use_block tool={tool} />
    </div>
    """
  end

  attr :tool, :map, required: true

  defp tool_use_block(assigns) do
    assigns =
      assigns
      |> assign(:tool_name, assigns.tool["name"])
      |> assign(:input, assigns.tool["input"] || %{})

    ~H"""
    <div class="ml-4 my-1">
      <details class="group">
        <summary class="flex items-center gap-2 cursor-pointer text-xs font-medium opacity-70 hover:opacity-100 transition-opacity">
          <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full bg-info/10 text-info">
            <.tool_icon name={@tool_name} />
            {@tool_name}
          </span>
          <span class="opacity-50 truncate max-w-md">
            <.tool_summary name={@tool_name} input={@input} />
          </span>
          <.icon name="hero-chevron-right-micro" class="size-3 opacity-50 group-open:rotate-90 transition-transform" />
        </summary>
        <div class="mt-1 ml-2 pl-3 border-l-2 border-info/20">
          <.tool_detail name={@tool_name} input={@input} />
        </div>
      </details>
    </div>
    """
  end

  attr :result, :map, required: true

  defp tool_result_block(assigns) do
    content = format_tool_result_content(assigns.result)
    assigns = assign(assigns, :content, content)

    ~H"""
    <div :if={@content != ""} class="ml-4 my-1">
      <details class="group">
        <summary class="flex items-center gap-2 cursor-pointer text-xs font-medium opacity-70 hover:opacity-100 transition-opacity">
          <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full bg-success/10 text-success">
            <.icon name="hero-check-circle-micro" class="size-3" />
            Result
          </span>
          <.icon name="hero-chevron-right-micro" class="size-3 opacity-50 group-open:rotate-90 transition-transform" />
        </summary>
        <div class="mt-1 ml-2 pl-3 border-l-2 border-success/20">
          <pre class="text-xs opacity-60 whitespace-pre-wrap overflow-x-auto max-h-64 overflow-y-auto">{@content}</pre>
        </div>
      </details>
    </div>
    """
  end

  attr :msg, :map, required: true

  defp result_message(assigns) do
    cost = assigns.msg["total_cost_usd"]
    duration = assigns.msg["duration_ms"]

    assigns =
      assigns
      |> assign(:cost, if(cost, do: "$#{Float.round(cost / 1, 4)}", else: "?"))
      |> assign(:duration, format_duration(duration))

    ~H"""
    <div class="flex items-center gap-3 text-xs opacity-50 py-2 my-2 border-t border-base-300">
      <span class="inline-flex items-center gap-1">
        <.icon name="hero-banknotes-micro" class="size-3" />
        {@cost}
      </span>
      <span class="inline-flex items-center gap-1">
        <.icon name="hero-clock-micro" class="size-3" />
        {@duration}
      </span>
    </div>
    """
  end

  attr :msg, :map, required: true

  defp system_message(assigns) do
    assigns = assign(assigns, :subtype, assigns.msg["subtype"])

    ~H"""
    <div class="flex items-center gap-1.5 text-xs opacity-40 italic py-1">
      <.icon name="hero-cog-6-tooth-micro" class="size-3" />
      {@subtype}
    </div>
    """
  end

  attr :msg, :map, required: true

  defp cli_error_message(assigns) do
    assigns =
      assigns
      |> assign(:exit_code, assigns.msg["exit_code"])
      |> assign(:message, assigns.msg["message"])

    ~H"""
    <div class="my-2 rounded-lg bg-error/10 border border-error/30 p-3">
      <div class="flex items-center gap-1.5 text-xs font-medium text-error mb-1">
        <.icon name="hero-exclamation-triangle-micro" class="size-3" />
        CLI error (exit code {@exit_code})
      </div>
      <pre class="text-xs text-error/80 whitespace-pre-wrap overflow-x-auto max-h-64 overflow-y-auto">{@message}</pre>
    </div>
    """
  end

  # Tool icons

  attr :name, :string, required: true

  defp tool_icon(%{name: "Bash"} = assigns) do
    ~H"""
    <.icon name="hero-command-line-micro" class="size-3" />
    """
  end

  defp tool_icon(%{name: name} = assigns) when name in ~w(Read Write) do
    ~H"""
    <.icon name="hero-document-text-micro" class="size-3" />
    """
  end

  defp tool_icon(%{name: "Edit"} = assigns) do
    ~H"""
    <.icon name="hero-pencil-square-micro" class="size-3" />
    """
  end

  defp tool_icon(%{name: name} = assigns) when name in ~w(Glob Grep) do
    ~H"""
    <.icon name="hero-magnifying-glass-micro" class="size-3" />
    """
  end

  defp tool_icon(%{name: name} = assigns) when name in ~w(WebFetch WebSearch) do
    ~H"""
    <.icon name="hero-globe-alt-micro" class="size-3" />
    """
  end

  defp tool_icon(%{name: "TodoWrite"} = assigns) do
    ~H"""
    <.icon name="hero-clipboard-document-list-micro" class="size-3" />
    """
  end

  defp tool_icon(assigns) do
    ~H"""
    <.icon name="hero-wrench-screwdriver-micro" class="size-3" />
    """
  end

  # Tool summary - short one-liner shown next to the tool name

  attr :name, :string, required: true
  attr :input, :map, required: true

  defp tool_summary(%{name: "Bash", input: input} = assigns) do
    assigns = assign(assigns, :cmd, truncate(input["command"] || "", 80))

    ~H"""
    <code class="text-xs">{@cmd}</code>
    """
  end

  defp tool_summary(%{name: name, input: input} = assigns) when name in ~w(Read Write) do
    assigns = assign(assigns, :path, input["file_path"] || "")

    ~H"""
    <code class="text-xs">{@path}</code>
    """
  end

  defp tool_summary(%{name: "Edit", input: input} = assigns) do
    assigns = assign(assigns, :path, input["file_path"] || "")

    ~H"""
    <code class="text-xs">{@path}</code>
    """
  end

  defp tool_summary(%{name: "Glob", input: input} = assigns) do
    assigns = assign(assigns, :pattern, input["pattern"] || "")

    ~H"""
    <code class="text-xs">{@pattern}</code>
    """
  end

  defp tool_summary(%{name: "Grep", input: input} = assigns) do
    assigns =
      assigns
      |> assign(:pattern, input["pattern"] || "")
      |> assign(:path, input["path"])

    ~H"""
    <code class="text-xs">{@pattern}</code>
    <span :if={@path} class="text-xs"> in {@path}</span>
    """
  end

  defp tool_summary(%{name: "WebFetch", input: input} = assigns) do
    assigns = assign(assigns, :url, truncate(input["url"] || "", 60))

    ~H"""
    <span class="text-xs">{@url}</span>
    """
  end

  defp tool_summary(%{name: "WebSearch", input: input} = assigns) do
    assigns = assign(assigns, :query, input["query"] || "")

    ~H"""
    <span class="text-xs">{@query}</span>
    """
  end

  defp tool_summary(assigns) do
    ~H"""
    """
  end

  # Tool detail - expanded content inside the details element

  attr :name, :string, required: true
  attr :input, :map, required: true

  defp tool_detail(%{name: "Bash", input: input} = assigns) do
    assigns = assign(assigns, :command, input["command"] || "")

    ~H"""
    <div class="bg-base-300 rounded p-2 font-mono text-xs overflow-x-auto">
      <pre class="whitespace-pre-wrap">{@command}</pre>
    </div>
    """
  end

  defp tool_detail(%{name: "Edit", input: input} = assigns) do
    assigns =
      assigns
      |> assign(:path, input["file_path"] || "?")
      |> assign(:old, input["old_string"] || "")
      |> assign(:new, input["new_string"] || "")

    ~H"""
    <div class="text-xs space-y-1">
      <div class="font-mono opacity-70">{@path}</div>
      <div :if={@old != ""} class="bg-error/10 text-error rounded p-2 font-mono overflow-x-auto">
        <pre class="whitespace-pre-wrap">- {@old}</pre>
      </div>
      <div :if={@new != ""} class="bg-success/10 text-success rounded p-2 font-mono overflow-x-auto">
        <pre class="whitespace-pre-wrap">+ {@new}</pre>
      </div>
    </div>
    """
  end

  defp tool_detail(%{name: "TodoWrite", input: input} = assigns) do
    assigns = assign(assigns, :todos, input["todos"] || [])

    ~H"""
    <div class="text-xs space-y-1">
      <div :for={todo <- @todos} class="flex items-center gap-2">
        <span :if={todo["status"] == "completed"} class="text-success">[x]</span>
        <span :if={todo["status"] == "in_progress"} class="text-warning">[~]</span>
        <span :if={todo["status"] not in ["completed", "in_progress"]}>[ ]</span>
        <span>{todo["content"]}</span>
      </div>
    </div>
    """
  end

  defp tool_detail(%{name: _name, input: input} = assigns) do
    assigns = assign(assigns, :json, Jason.encode!(input, pretty: true))

    ~H"""
    <pre class="text-xs opacity-60 whitespace-pre-wrap overflow-x-auto">{@json}</pre>
    """
  end

  # Helpers

  defp format_tool_result_content(%{"content" => content}) when is_binary(content) do
    truncate(content, 3000)
  end

  defp format_tool_result_content(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map_join("\n", fn
      %{"type" => "text", "text" => text} -> text
      other -> inspect(other, pretty: true, limit: 200)
    end)
    |> truncate(3000)
  end

  # tool_use_result from top-level has file.content or text directly
  defp format_tool_result_content(%{"type" => "text", "file" => %{"content" => content}}) do
    truncate(content, 3000)
  end

  defp format_tool_result_content(%{"type" => "text", "text" => text}) do
    truncate(text, 3000)
  end

  defp format_tool_result_content(_), do: ""

  defp truncate(str, max) do
    if String.length(str) > max, do: String.slice(str, 0, max) <> "\n…truncated", else: str
  end

  attr :value, :any, required: true

  defp timestamp(assigns) do
    assigns = assign(assigns, :formatted, format_timestamp(assigns.value))

    ~H"""
    <time :if={@formatted} class="opacity-70">{@formatted}</time>
    """
  end

  defp format_timestamp(%NaiveDateTime{} = ts) do
    utc = DateTime.from_naive!(ts, "Etc/UTC")

    case DateTime.shift_zone(utc, "America/New_York") do
      {:ok, local} -> Calendar.strftime(local, "%-I:%M %p")
      {:error, _} -> Calendar.strftime(utc, "%-I:%M %p UTC")
    end
  end

  defp format_timestamp(_), do: nil

  defp format_duration(nil), do: "?"
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp extract_attachments(text) do
    # Extract [Attached image: path] and [Attached file: path] tags
    image_matches = Regex.scan(~r/\[Attached image: (.+?)\]/, text)
    file_matches = Regex.scan(~r/\[Attached file: (.+?)\]/, text)

    attachments =
      Enum.map(image_matches, fn [_, path] -> {:image, path} end) ++
        Enum.map(file_matches, fn [_, path] -> {:file, path} end)

    clean_text =
      text
      |> String.replace(~r/\n*\[Attached (?:image|file): .+?\]/, "")
      |> String.replace(~r/^I've attached files to the session directory\. Please review them\.\s*/, "")
      |> String.trim()

    {clean_text, attachments}
  end

  defp image_data_uri(path) do
    case File.read(path) do
      {:ok, data} ->
        ext = path |> Path.extname() |> String.downcase()

        mime =
          case ext do
            ".jpg" -> "image/jpeg"
            ".jpeg" -> "image/jpeg"
            ".png" -> "image/png"
            ".gif" -> "image/gif"
            ".webp" -> "image/webp"
            _ -> "image/png"
          end

        "data:#{mime};base64,#{Base.encode64(data)}"

      {:error, _} ->
        ""
    end
  end
end
