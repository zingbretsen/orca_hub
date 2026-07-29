defmodule OrcaHub.Discord.FileFilter do
  @moduledoc """
  The single choke point every file crossing the Discord I/O boundary passes
  through, in either direction: an upload landing in a project's `inbox/`
  (`OrcaHub.Discord.Bridge`'s on-mention auto-copy, and the
  `fetch_discord_attachments` MCP tool), or a file being attached to an
  outbound `send_discord_message` post (`OrcaHub.MCP.Tools.Discord`).

  ## Why one choke point

  Before this module, size limits were duplicated ad hoc at each call site
  (`Tools.Discord` had its own `@max_fetch_bytes`/`@max_total_bytes`
  constants; `Bridge`'s auto-copy path had no limit at all — see the git
  history around the introduction of this module for the hole that left).
  Every future rule — content scanning, per-channel trust tiers, whatever
  comes next — should only ever need to be written ONCE, here, and every
  boundary automatically gets it. Call sites are expected to build a context
  map and call the relevant hook; they should never re-implement a policy
  decision locally.

  ## The three hooks

  Each returns `:allow | {:deny, reason_string}`. `reason_string` is
  user/log-facing — safe to show the caller (a Discord user, or the agent
  session) and to write to the log, but MUST NOT itself leak anything the
  caller didn't already know (see `OrcaHub.MCP.Tools.Discord`'s path
  confinement for the sibling rule about not echoing resolved filesystem
  paths).

    * `check_inbound_metadata(ctx)` — called BEFORE the Discord CDN download.
      Only metadata Discord's message payload already gave us is known:
      declared filename, declared size, extension-guessed content type.
      **The bytes are not in hand.** This is the cheap, early rejection —
      catches an obviously-oversized file before spending any bandwidth on
      it.

    * `check_inbound_content(ctx)` — called AFTER the download, with the
      actual bytes in hand (`ctx.bytes`), but BEFORE those bytes are
      written to the shared mount (`File.write!`). This is the last chance
      to reject an inbound file — catches anything the metadata hook
      couldn't judge (e.g. a missing/lying declared size) using ground
      truth. A denial here must leave no partial file on disk — callers are
      responsible for only calling `File.write!` after this hook allows.

    * `check_outbound(ctx)` — called for each `file_paths` entry on
      `send_discord_message`, once the path has already been confined to
      the session's own directory (see below) and confirmed to exist. This
      is the last chance to reject a file before its bytes leave the
      cluster to a Discord channel.

  ## Context maps

  Every field a rule could plausibly want is included on every call, even
  the ones nothing reads yet — the point is that adding a new rule should
  never require re-plumbing a call site to pass one more field through.

  Inbound (`check_inbound_metadata/1`, plus `check_inbound_content/1` which
  adds `:bytes`):

    * `:direction` — always `:inbound`
    * `:project` — the owning `OrcaHub.Projects.Project`, for rules that
      care about project-level policy
    * `:directory` — the project's working directory (absolute path)
    * `:message_id` — the Discord message the file arrived on
    * `:original_filename` — exactly as Discord reported it
    * `:sanitized_filename` — after `Bridge.sanitize_filename/1`
    * `:size` — declared (metadata) or actual (content) byte count; `nil`
      if genuinely unknown
    * `:content_type` — best-effort MIME guess from the filename extension
      (NOT sniffed from bytes — see "deliberately not handled yet" below)
    * `:mapping` — the `OrcaHub.DiscordChannels.DiscordChannel` row, so a
      future rule can branch on which channel/trust tier a file arrived
      through
    * `:bytes` — (content hook only) the downloaded body

  Outbound (`check_outbound/1`):

    * `:direction` — always `:outbound`
    * `:session_id` — the sending session
    * `:directory` — the session's working directory
    * `:path` — the resolved absolute path (already confinement-checked)
    * `:filename` — basename
    * `:size`, `:content_type`, `:mapping` — as above

  ## How to add a rule

  Pattern-match/guard inside the relevant `check_*` function (or extract a
  private helper it delegates to, the way `check_size/1` below is shared by
  all three hooks for the one rule that exists today) and return
  `{:deny, reason}` instead of falling through to `:allow`. Reach for a
  ctx field before adding a new one — most rules should need zero call-site
  changes.

  ## What's implemented today

  Every hook is a pure passthrough (`:allow`) EXCEPT ONE rule: a per-file
  size cap (`check_size/1`, backing all three hooks) plus a per-message/
  per-call total cap (`check_total/2`, used by callers that need to sum
  across several files — see the moduledoc note on `check_total/2` for why
  that one isn't shaped as a fourth ctx-based hook). That's it. One real
  rule, wired end-to-end at every boundary, is the worked example the next
  rule copies.

  ## Deliberately NOT handled yet

  These are explicitly out of scope for this pass — noted here so "should
  we add X" has one obvious place to check before it's re-discovered as a
  gap:

    * Content/malware scanning of inbound bytes
    * Secret/entropy detection on outbound files (an agent could still
      attach `.env` or a credential file to a Discord post — nothing here
      stops that today)
    * Per-channel public-vs-private trust tiers (the `:mapping` field
      exists on every ctx specifically so this can be added later without
      touching call sites)
    * MIME sniffing — `:content_type` is an extension guess
      (`MIME.from_path/1`), never inspected against the actual bytes

  ## This is NOT a sandbox

  This module governs the DISCORD I/O BOUNDARY ONLY — the moment a file
  crosses between the shared mount and Discord's CDN/API. It has no opinion
  about, and no visibility into, anything else a session does with its own
  filesystem: an agent can `Read`/`Write`/`Bash` freely within its working
  directory regardless of what this module would say about a Discord
  transfer of the same bytes. In particular:

    * A file this module denied on the way in was never written — but a
      session can still create an identical file itself via any other tool.
    * A file this module would deny on the way out can still be read,
      edited, or shared through any non-Discord channel the session has
      access to.

  Path CONFINEMENT (making sure a `send_discord_message` `file_paths` entry
  actually resolves inside the session's own directory, closing a
  directory-traversal/symlink-escape hole) is a separate, complementary
  control that lives in `OrcaHub.MCP.Tools.Discord` — by design: confinement
  decides WHICH files are even eligible to reach this filter at all; this
  filter then decides whether an eligible file is ALLOWED. Neither
  subsumes the other.
  """

  # Per-file cap, in bytes. The ONE definition — `OrcaHub.MCP.Tools.Discord`
  # used to keep its own separate 25MB constant for fetch_discord_attachments
  # (and had no per-file cap at all for send_discord_message); both now read
  # this via `max_file_bytes/0` so a re-tune can't silently miss a stale copy
  # elsewhere. 25MB comfortably covers ordinary documents/images/short clips
  # without leaving the door open to Discord's real per-file ceiling (up to
  # 500MB on a boosted server).
  @max_file_bytes 25 * 1024 * 1024

  # Per-message/per-call total cap for INBOUND transfers, in bytes — bounds
  # how much a single Discord event (one @-mention's attachments, or one
  # fetch_discord_attachments call) can dump onto the shared mount in
  # aggregate. Deliberately distinct from (and larger than) the per-file cap:
  # several individually-small files could otherwise add up to something
  # huge with no per-file trip. Set to ~1.6x the per-file cap — enough slack
  # for a couple of sizeable files together (e.g. a document plus a cover
  # image) without leaving auto-copy anywhere near as open as it is with NO
  # total cap at all today. Trivially tunable — one attribute, read nowhere
  # else.
  @max_inbound_total_bytes 40 * 1024 * 1024

  @doc "The per-file cap in bytes — the single source of truth every boundary shares."
  def max_file_bytes, do: @max_file_bytes

  @doc "The per-message/per-call inbound total cap in bytes."
  def max_inbound_total_bytes, do: @max_inbound_total_bytes

  @doc """
  Check a file before it is downloaded from Discord — metadata only (name,
  declared size, guessed content type), no bytes in hand yet. See moduledoc.
  """
  @spec check_inbound_metadata(map()) :: :allow | {:deny, String.t()}
  def check_inbound_metadata(ctx), do: check_size(ctx)

  @doc """
  Check a file after it has been downloaded (bytes in `ctx.bytes`) but
  before it is written to disk. See moduledoc.
  """
  @spec check_inbound_content(map()) :: :allow | {:deny, String.t()}
  def check_inbound_content(ctx), do: check_size(ctx)

  @doc """
  Check a file immediately before it is attached to an outbound Discord
  post. See moduledoc.
  """
  @spec check_outbound(map()) :: :allow | {:deny, String.t()}
  def check_outbound(ctx), do: check_size(ctx)

  # The one implemented rule, shared by all three hooks. `size` may be `nil`
  # (declared size genuinely unknown at the metadata stage) — we can't judge
  # what we can't see, so that's an :allow here; the content hook re-checks
  # with the real byte count once it's known, closing that gap.
  defp check_size(%{size: size}) when is_integer(size) and size > @max_file_bytes do
    {:deny,
     "is #{format_bytes(size)}, exceeding the #{format_bytes(@max_file_bytes)} per-file limit"}
  end

  defp check_size(_ctx), do: :allow

  @doc """
  Generic "does this total exceed a cap" check, shared by every batch/total
  guard across both directions (inbound auto-copy, inbound
  fetch_discord_attachments, and outbound send_discord_message's existing
  Discord-upload-size total) — the comparison itself lives in one place even
  though each caller supplies its own cap value (outbound's is Discord's own
  upload-size constraint, not an abuse-prevention policy this module owns)
  and builds its own user-facing wording around the result.

  Not one of the three ctx-based hooks above: "total across N files" doesn't
  fit a single-file ctx, so this is a plain arithmetic helper instead.
  """
  @spec check_total(non_neg_integer(), non_neg_integer()) :: :allow | {:deny, String.t()}
  def check_total(total_bytes, cap_bytes)
      when is_integer(total_bytes) and is_integer(cap_bytes) do
    if total_bytes > cap_bytes do
      {:deny,
       "total is #{format_bytes(total_bytes)}, exceeding the #{format_bytes(cap_bytes)} limit"}
    else
      :allow
    end
  end

  @doc "Human-readable byte size, shared so every denial/log message formats sizes identically."
  def format_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)}MB"
  def format_bytes(bytes), do: "#{Float.round(bytes / 1024, 1)}KB"
end
