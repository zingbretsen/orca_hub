defmodule OrcaHubWeb.BlockEditor do
  @moduledoc """
  Shared tap-to-edit/delete markdown block renderer, used by
  `OrcaHubWeb.ProjectLive.Show` for both the project file viewer and the
  Agent Memory viewers (Claude memory files, the Claude `MEMORY.md` index,
  Codex native memory files).

  A block's identity on the wire is `{scope, target_key, index}` — `scope`
  routes `save_block`/`delete_block` to the right persistence call
  (`"project_file"`, `"claude_memory"`, `"claude_index"`, `"codex_memory"`),
  `target_key` disambiguates between multiple simultaneously-expanded files
  within the same scope (e.g. two expanded Claude memories), and `index` is
  the block's position as produced by `OrcaHubWeb.Markdown.split_blocks/1`.
  """
  use Phoenix.Component

  import OrcaHubWeb.CoreComponents, only: [icon: 1]

  alias OrcaHubWeb.Markdown

  attr :scope, :string, required: true
  attr :target_key, :string, default: ""
  attr :blocks, :list, required: true
  attr :frontmatter, :string, default: nil
  attr :dom_prefix, :string, required: true
  attr :editing_block, :map, default: nil
  attr :block_edit_content, :string, default: nil

  def block_editor(assigns) do
    ~H"""
    <div class="bg-base-200 rounded-lg p-4">
      <div
        :if={@frontmatter}
        class="mb-3 rounded bg-base-300/40 px-3 py-2 text-xs font-mono whitespace-pre-wrap text-base-content/50"
        title="YAML frontmatter — not block-editable, use Raw Edit"
      >
        {@frontmatter}
      </div>
      <div :for={{index, block_text} <- @blocks} class="group relative">
        <div :if={block_editing?(@editing_block, @scope, @target_key, index)} class="my-2">
          <form phx-submit="save_block" class="space-y-2">
            <textarea
              name="content"
              class="textarea textarea-bordered w-full font-mono text-sm"
              rows={max(3, length(String.split(block_text, "\n")) + 1)}
              phx-hook="AutoFocus"
              id={"#{@dom_prefix}-editor-#{index}"}
            >{@block_edit_content}</textarea>
            <div class="flex justify-end gap-2">
              <button type="button" phx-click="cancel_block_edit" class="btn btn-xs">
                Cancel
              </button>
              <button type="submit" class="btn btn-xs btn-primary">Save</button>
            </div>
          </form>
        </div>
        <div :if={!block_editing?(@editing_block, @scope, @target_key, index)} class="relative group">
          <div
            phx-click="edit_block"
            phx-value-scope={@scope}
            phx-value-key={@target_key}
            phx-value-index={index}
            class="prose prose-sm max-w-none cursor-pointer rounded px-2 -mx-2 py-1 hover:bg-base-300/50 transition-colors"
          >
            {Markdown.render_block(block_text)}
          </div>
          <button
            phx-click="delete_block"
            phx-value-scope={@scope}
            phx-value-key={@target_key}
            phx-value-index={index}
            class="absolute top-1 right-1 btn btn-ghost btn-xs opacity-0 group-hover:opacity-100 transition-opacity text-error"
            title="Delete block"
          >
            <.icon name="hero-trash-micro" class="size-3" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp block_editing?(%{scope: scope, key: key, index: index}, scope, key, index), do: true
  defp block_editing?(_editing_block, _scope, _key, _index), do: false
end
