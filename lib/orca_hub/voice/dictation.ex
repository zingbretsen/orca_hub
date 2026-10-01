defmodule OrcaHub.Voice.Dictation do
  @moduledoc """
  The note that tells an agent a message was composed by voice dictation, so
  it reads "Nemo Tron" as Nemotron rather than taking the transcript
  literally. The wording lives HERE and nowhere else.

  It is a per-message PREFIX on the prompt text itself, never part of a
  system prompt (those are byte-pinned by goldens). Riding inside the
  string is what makes it backend-agnostic (claude/codex/pi all receive the
  same prompt) and what lets it survive `:queue` delivery, which batches
  queued strings behind a `[Message delivery note]` header — so a reader
  must not assume the note is at position 0 (`strip/1` doesn't).

  Both voice send paths apply it (spec §8.2 / C4):

    * composer path — the `Voice` hook `requestSubmit`s the composer with
      its hidden `voice_dictated` submit button as the submitter, and
      `SessionLive.Show`'s `send_message` prefixes when that param is
      present;
    * direct path (`send_direct`, or the no-composer deadline fallback) —
      `OrcaHubWeb.VoiceChannel` prefixes the `{:send, text}` effect.

  Display: the user bubble shows a small "dictated" marker instead of the
  note (`OrcaHubWeb.MessageComponents`), the same display-only treatment
  the leading `<orca-memory>` block gets. Stored data keeps the note.
  """

  @note "[Dictated via speech recognition — expect misheard words, homophones " <>
          "and odd punctuation; infer the intended meaning.]"
  @separator "\n\n"

  # The note counts only as a whole paragraph of its own: at the start of the
  # text or of a line, followed by the separator. A message that merely
  # QUOTES the note mid-sentence is left alone.
  @marker ~r/(?:\A|(?<=\n))#{Regex.escape(@note)}\n\n/u

  @doc "The note itself."
  def note, do: @note

  @doc "`text` with the note as its leading paragraph."
  @spec prefix(String.t()) :: String.t()
  def prefix(text) when is_binary(text), do: @note <> @separator <> text

  @doc """
  Removes every note paragraph from `text` and says whether there was one:
  `{dictated?, text}`. Paragraph-anchored, so it also finds the note behind
  a queued-delivery header or a leading `<orca-memory>` block.
  """
  @spec strip(String.t()) :: {boolean(), String.t()}
  def strip(text) when is_binary(text) do
    if String.contains?(text, @note) do
      stripped = String.replace(text, @marker, "")
      {stripped != text, stripped}
    else
      {false, text}
    end
  end

  def strip(other), do: {false, other}
end
