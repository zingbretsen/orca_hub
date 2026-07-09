defmodule OrcaHubWeb.NodeLive.ConfigComponents do
  @moduledoc """
  Function components for rendering a single `OrcaHub.NodeConfig` catalog
  entry (file or directory) inside `NodeLive.Show`'s Backend Configuration
  section. Split out of `show.html.heex` because directory rows recurse
  into file rows for their children (a flat dir's files, or a skill's
  `SKILL.md`).
  """
  use Phoenix.Component

  import OrcaHubWeb.CoreComponents, only: [icon: 1]

  import OrcaHubWeb.NodeLive.ConfigHelpers,
    only: [entry_key: 2, flag_label: 1, format_label: 1, split_config_blocks: 2]

  alias OrcaHub.ConfigFile
  alias OrcaHubWeb.{BlockEditor, StructuredEditor}

  attr :backend, :atom, required: true
  attr :entry, :map, required: true
  attr :config_expanded, :any, required: true
  attr :config_editing, :any, required: true
  attr :config_edit_content, :string, required: true
  attr :config_content, :map, required: true
  attr :editing_block, :any, required: true
  attr :block_edit_content, :any, required: true
  attr :config_view_mode, :any, required: true
  attr :structured_editing, :any, required: true
  attr :structured_edit_value, :string, required: true

  def config_file_row(assigns) do
    assigns = assign(assigns, :key, entry_key(assigns.backend, assigns.entry.path))

    ~H"""
    <div class="bg-base-100 rounded p-3">
      <div class="flex items-center justify-between gap-2 flex-wrap">
        <div class="flex items-center gap-2 min-w-0">
          <span class="font-mono text-sm">{@entry.label}</span>
          <span class="badge badge-xs badge-ghost">{format_label(@entry.format)}</span>
          <span :for={flag <- @entry.flags} class="badge badge-xs badge-warning">
            {flag_label(flag)}
          </span>
          <span :if={!@entry.exists?} class="badge badge-xs badge-neutral">missing</span>
        </div>

        <div class="flex items-center gap-1">
          <button
            :if={@entry.exists?}
            phx-click="toggle_config_entry"
            phx-value-key={@key}
            class="btn btn-xs btn-ghost"
          >
            {if MapSet.member?(@config_expanded, @key), do: "Hide", else: "View"}
          </button>
          <button
            :if={@entry.exists? && :view_only not in @entry.flags}
            phx-click="edit_config_entry"
            phx-value-key={@key}
            class="btn btn-xs btn-ghost"
          >
            Edit
          </button>
          <button
            :if={!@entry.exists? && @entry.create_template}
            phx-click="edit_config_entry"
            phx-value-key={@key}
            class="btn btn-xs btn-primary"
          >
            Create
          </button>
          <button
            :if={@entry.exists? && :view_only not in @entry.flags}
            phx-click="delete_config_entry"
            phx-value-key={@key}
            data-confirm={"Delete #{@entry.label}?"}
            class="btn btn-xs btn-ghost text-error"
          >
            Delete
          </button>
        </div>
      </div>

      <p :if={:view_only in @entry.flags} class="text-xs text-warning mt-1">
        View-only — hand-editing this can silently grant a project trust it shouldn't have.
      </p>

      <div :if={@config_editing == @key} class="mt-2">
        <form phx-submit="save_config_entry" class="space-y-2">
          <input type="hidden" name="key" value={@key} />
          <textarea
            name="content"
            id={"config-editor-#{@backend}-#{@entry.path}"}
            class="textarea textarea-bordered w-full font-mono text-sm"
            rows="12"
          >{@config_edit_content}</textarea>
          <div class="flex justify-end gap-2">
            <button type="button" phx-click="cancel_edit_config_entry" class="btn btn-xs">
              Cancel
            </button>
            <button type="submit" class="btn btn-xs btn-primary">Save</button>
          </div>
        </form>
      </div>

      <div :if={@config_editing != @key && MapSet.member?(@config_expanded, @key)} class="mt-2">
        <%= cond do %>
          <% @entry.format == :markdown -> %>
            <% {frontmatter, blocks} = split_config_blocks(@config_content, @key) %>
            <BlockEditor.block_editor
              scope="node_config"
              target_key={@key}
              blocks={blocks}
              frontmatter={frontmatter}
              dom_prefix={"config-block-#{@backend}-#{@entry.path}"}
              editing_block={@editing_block}
              block_edit_content={@block_edit_content}
            />
          <% ConfigFile.supported?(@entry.format) -> %>
            <StructuredEditor.structured_or_raw
              scope="node_config"
              target_key={@key}
              dom_prefix={"config-struct-#{@backend}-#{@entry.path}"}
              content={Map.get(@config_content, @key, "")}
              format={@entry.format}
              view_mode={Map.get(@config_view_mode, @key, :structured)}
              editing={@structured_editing}
              edit_value={@structured_edit_value}
            />
          <% true -> %>
            <div class="bg-base-200 rounded-lg p-3">
              <pre class="text-sm font-mono whitespace-pre-wrap break-words">{Map.get(@config_content, @key, "")}</pre>
            </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :backend, :atom, required: true
  attr :entry, :map, required: true
  attr :config_dirs_expanded, :any, required: true
  attr :config_expanded, :any, required: true
  attr :config_editing, :any, required: true
  attr :config_edit_content, :string, required: true
  attr :config_content, :map, required: true
  attr :config_new_entry, :any, required: true
  attr :config_new_entry_name, :string, required: true
  attr :config_new_entry_content, :string, required: true
  attr :editing_block, :any, required: true
  attr :block_edit_content, :any, required: true
  attr :config_view_mode, :any, required: true
  attr :structured_editing, :any, required: true
  attr :structured_edit_value, :string, required: true

  def config_dir_row(assigns) do
    assigns = assign(assigns, :dir_key, {assigns.backend, assigns.entry.path})

    ~H"""
    <div class="bg-base-100 rounded p-3">
      <div
        class="flex items-center gap-2 cursor-pointer flex-wrap"
        phx-click="toggle_config_dir"
        phx-value-backend={@backend}
        phx-value-path={@entry.path}
      >
        <.icon
          name={
            if MapSet.member?(@config_dirs_expanded, @dir_key),
              do: "hero-chevron-down-micro",
              else: "hero-chevron-right-micro"
          }
          class="size-4"
        />
        <span class="font-mono text-sm">{@entry.label}</span>
        <span class="badge badge-xs badge-ghost">{format_label(@entry.format)}</span>
        <span :for={flag <- @entry.flags} class="badge badge-xs badge-warning">
          {flag_label(flag)}
        </span>
        <span :if={!@entry.exists?} class="badge badge-xs badge-neutral">missing</span>
      </div>

      <div :if={MapSet.member?(@config_dirs_expanded, @dir_key)} class="mt-2 pl-6 space-y-2">
        <div :if={!@entry.exists?}>
          <button
            phx-click="create_config_dir"
            phx-value-backend={@backend}
            phx-value-path={@entry.path}
            class="btn btn-xs btn-primary"
          >
            Create directory
          </button>
        </div>

        <div :if={@entry.exists? && @entry.children == []} class="text-xs text-base-content/50">
          No files yet.
        </div>

        <div
          :for={child <- @entry.children}
          id={"config-child-#{@backend}-#{child.path}"}
          class="border-t border-base-300 pt-2 first:border-t-0 first:pt-0"
        >
          <.config_file_row
            backend={@backend}
            entry={child_entry(@entry, child)}
            config_expanded={@config_expanded}
            config_editing={@config_editing}
            config_edit_content={@config_edit_content}
            config_content={@config_content}
            editing_block={@editing_block}
            block_edit_content={@block_edit_content}
            config_view_mode={@config_view_mode}
            structured_editing={@structured_editing}
            structured_edit_value={@structured_edit_value}
          />
        </div>

        <div :if={@entry.create_template} class="mt-1">
          <button
            :if={!new_entry_open?(@config_new_entry, @backend, @entry.path)}
            phx-click="new_config_entry"
            phx-value-backend={@backend}
            phx-value-dir_path={@entry.path}
            class="btn btn-xs btn-ghost"
          >
            {if @entry.dir_kind == :skill_dirs, do: "New skill", else: "New file"}
          </button>

          <form
            :if={new_entry_open?(@config_new_entry, @backend, @entry.path)}
            phx-submit="save_new_config_entry"
            class="space-y-2 mt-2"
          >
            <input
              type="text"
              name="name"
              placeholder={if @entry.dir_kind == :skill_dirs, do: "skill-name", else: "filename.md"}
              class="input input-bordered input-sm w-full font-mono"
            />
            <textarea
              name="content"
              class="textarea textarea-bordered w-full font-mono text-sm"
              rows="8"
            >{@config_new_entry_content}</textarea>
            <div class="flex justify-end gap-2">
              <button type="button" phx-click="cancel_new_config_entry" class="btn btn-xs">
                Cancel
              </button>
              <button type="submit" class="btn btn-xs btn-primary">Create</button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  # Builds a file-row-shaped entry for a dir's child (a flat file, or a
  # skill's SKILL.md), inheriting format/flags/create_template from the
  # parent dir entry. `:flat` children are only ever listed when the file
  # already exists on disk (see `NodeConfig.dir_children/2`); `:skill_dirs`
  # children carry their own `exists?` since a skill's subdirectory can
  # exist before its `SKILL.md` does.
  defp child_entry(dir_entry, child) do
    %{
      path: child.path,
      label: child.name,
      format: dir_entry.format,
      flags: dir_entry.flags,
      exists?: Map.get(child, :exists?, true),
      create_template: dir_entry.create_template
    }
  end

  defp new_entry_open?(nil, _backend, _dir_path), do: false

  defp new_entry_open?(%{backend: backend, dir_path: dir_path}, backend, dir_path), do: true
  defp new_entry_open?(_new_entry, _backend, _dir_path), do: false
end
