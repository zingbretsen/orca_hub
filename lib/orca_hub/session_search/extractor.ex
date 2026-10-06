defmodule OrcaHub.SessionSearch.Extractor do
  @moduledoc """
  Pure translation of one `messages` row (+ its session) into a
  memory-service `session-messages` doc, or `:skip`.

  Every backend normalizes onto Claude's stream-json shape, so one code path
  covers Claude, Codex and pi:

    * `type: "user"`, `message.content` a string or a list with `text`
      blocks -> role `user`. The leading `<orca-memory>` block (65% of all
      prompt text, identical boilerplate) is stripped; other prefixes —
      `[Dictated via speech recognition ...]`, `[Session lifecycle]`,
      `[Message delivery note]` — are real content and kept.
    * `type: "assistant"` -> the `text` blocks only, joined with a newline,
      role `assistant`.

  Skipped: tool_use / tool_result / thinking / document blocks (a user
  message that only carries tool results has no text block), system / result
  / rate_limit / cli_error / pi_* events, empty text, subagent traffic
  (`parent_tool_use_id` set: the parent's own text carries the outcome), and
  Claude's `isMeta` / `isSynthetic` user rows (slash-command and skill
  template expansions, not what anyone said) and user text made only of
  `<command-*>`/`<local-command-*>` echo tags. `isCompactSummary` rows are
  kept — they are a model-written summary of the session.

  Background sessions (`kind != "session"`, e.g. `memory_extraction`) are
  skipped as a whole: they replay other sessions' transcripts.
  """

  alias OrcaHub.Sessions.{Message, Session}

  # Hard ceiling per doc; memory-service chunks long text itself, this only
  # bounds a pathological message.
  @max_chars 200_000

  @memory_block_open "<orca-memory>\n"
  @memory_block_close "\n</orca-memory>\n\n"

  @doc "Builds the contract doc for `message`, or returns `:skip`."
  @spec extract(Message.t(), Session.t()) :: {:ok, map()} | :skip
  def extract(%Message{data: data} = message, %Session{kind: "session"} = session)
      when is_map(data) do
    with {:ok, role, text} <- role_and_text(data),
         text = text |> String.trim() |> String.slice(0, @max_chars),
         true <- text != "",
         false <- role == "user" and command_echo_only?(text) do
      {:ok,
       %{
         "id" => message.id,
         "group_id" => message.session_id,
         "text" => text,
         "fields" => fields(role, message, session)
       }}
    else
      _ -> :skip
    end
  end

  def extract(_message, _session), do: :skip

  # Slash-command echoes (`<command-name>/exit</command-name>`,
  # `<local-command-stdout>…`) that are not flagged isMeta carry no
  # conversation; a user text made only of such tags is noise.
  @command_tag ~r/<(command-[a-z-]+|local-command-[a-z-]+)>.*?<\/\1>/s
  defp command_echo_only?(text),
    do: text |> String.replace(@command_tag, "") |> String.trim() == ""

  @doc "Whether the session's messages are indexed at all."
  def indexable_session?(%Session{kind: "session"}), do: true
  def indexable_session?(_), do: false

  defp role_and_text(%{"parent_tool_use_id" => id}) when not is_nil(id), do: :skip
  defp role_and_text(%{"isMeta" => true}), do: :skip
  defp role_and_text(%{"isSynthetic" => true}), do: :skip

  defp role_and_text(%{"type" => "user"} = data) do
    {:ok, "user", data |> text_of() |> strip_leading_memory_block()}
  end

  defp role_and_text(%{"type" => "assistant"} = data), do: {:ok, "assistant", text_of(data)}
  defp role_and_text(_data), do: :skip

  defp text_of(data) do
    case get_in(data, ["message", "content"]) do
      text when is_binary(text) ->
        text

      blocks when is_list(blocks) ->
        blocks
        |> Enum.filter(&(is_map(&1) and &1["type"] == "text" and is_binary(&1["text"])))
        |> Enum.map_join("\n", & &1["text"])

      _ ->
        ""
    end
  end

  # Same rule as OrcaHubWeb.MessageComponents.strip_leading_memory_block/1
  # (display-only there): only a LEADING block, split on the closing marker.
  @doc false
  def strip_leading_memory_block(text) do
    if String.starts_with?(text, @memory_block_open) do
      case String.split(text, @memory_block_close, parts: 2) do
        [_block, rest] -> rest
        _ -> text
      end
    else
      text
    end
  end

  defp fields(role, message, session) do
    %{
      "role" => role,
      "backend" => session.backend,
      "node" => session.runner_node,
      "project_id" => session.project_id,
      "directory" => session.directory,
      "inserted_at" => iso8601(message.inserted_at)
    }
    |> Enum.reject(fn {k, v} -> is_nil(v) and k != "project_id" end)
    |> Map.new()
  end

  # `messages.inserted_at` is :naive_datetime_usec (UTC by convention).
  defp iso8601(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
