defmodule OrcaHubWeb.NodeLive.ConfigHelpers do
  @moduledoc """
  Small presentation helpers shared by `OrcaHubWeb.NodeLive.Show` and
  `OrcaHubWeb.NodeLive.ConfigComponents`. Split into its own module so
  neither of those two has a compile-time dependency on the other (they'd
  otherwise deadlock: `Show`'s template calls into `ConfigComponents`, and
  `ConfigComponents` needs these helpers).
  """

  alias OrcaHubWeb.Markdown

  @doc ~S(Wire identity for a catalog entry, e.g. `"claude|CLAUDE.md"`.)
  def entry_key(backend, path), do: "#{backend}|#{path}"

  def flag_label(:legacy), do: "legacy"
  def flag_label(:deprecated), do: "deprecated"
  def flag_label(:view_only), do: "view only"
  def flag_label(:code_caution), do: "code — applies next session"

  def format_label(:markdown), do: "markdown"
  def format_label(:json), do: "JSON"
  def format_label(:toml), do: "TOML"
  def format_label(:code), do: "code"
  def format_label(:other), do: "other"

  @doc """
  Splits a config entry's raw content into `{frontmatter, blocks}` for the
  shared `OrcaHubWeb.BlockEditor` — every catalog `:markdown` entry may have
  a leading YAML frontmatter block (skills/agents/commands do; `CLAUDE.md`/
  `AGENTS.md` usually don't), split out the same way
  `OrcaHub.AgentMemory`'s Claude memory files are.
  """
  def split_config_blocks(config_content, key) do
    content = Map.get(config_content, key, "")
    {frontmatter, body} = Markdown.split_frontmatter(content)
    {frontmatter, Markdown.split_blocks(body)}
  end
end
