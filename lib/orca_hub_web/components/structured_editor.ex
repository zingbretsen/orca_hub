defmodule OrcaHubWeb.StructuredEditor do
  @moduledoc """
  Shared structured (tree) editor for config-style files, sibling of
  `OrcaHubWeb.BlockEditor` and modeled on its wire protocol — used by
  `OrcaHubWeb.NodeLive.Show` (Backend Configuration `:json` entries) and
  `OrcaHubWeb.ProjectLive.Show` (the project file viewer, for `.json`
  files). Renders the normalized tree `OrcaHub.ConfigFile.parse/2`
  produces: objects/arrays as collapsible `<details>` sections (native,
  client-side — no server round trip to expand/collapse), leaf values as
  click-to-edit rows, and an always-visible "add" row per object/array
  level.

  A node's identity on the wire is `{scope, target_key, path}` — `scope`
  routes `save_value`/`delete_key`/`add_key` to the right persistence call
  the same way it does for `BlockEditor` (`"node_config"`,
  `"project_file"`), `target_key` disambiguates between multiple
  simultaneously-open structured editors within the same scope, and `path`
  (wire-encoded via `OrcaHub.ConfigFile.encode_path/1`) addresses a node
  within the tree.

  Events bubble to the host LiveView, which is the only thing that ever
  applies an op (via `OrcaHub.ConfigFile.apply_op/3`) or touches disk:

    * `edit_value` — click a non-boolean leaf to open its inline edit form
    * `save_value` — submit that form, OR click a boolean leaf's toggle
      (fires directly, no separate edit step)
    * `delete_key` — remove a key/element (object member or array item)
    * `add_key` — submit an object/array level's always-visible add row
    * `cancel` — close the active `edit_value` form without saving

  All five events carry `scope`/`key` (`target_key`); `save_value`/
  `delete_key`/`add_key` additionally carry an encoded `path`, and
  `save_value`/`add_key` carry `value_type` + `value`.

  `structured_or_raw/1` (the Structured/Raw toggle both hosts render) adds
  a sixth, purely presentational event, `toggle_view_mode` (`scope`/`key`/
  `mode`) — it never touches the format layer or disk, just which of
  Structured vs Raw the host shows for this `scope`/`key`.
  """
  use Phoenix.Component

  import OrcaHubWeb.CoreComponents, only: [icon: 1]

  alias OrcaHub.ConfigFile

  attr :scope, :string, required: true
  attr :target_key, :string, default: ""
  attr :tree, :map, required: true
  attr :dom_prefix, :string, required: true
  attr :editing, :any, default: nil
  attr :edit_value, :string, default: ""

  def structured_editor(assigns) do
    ~H"""
    <div class="bg-base-200 rounded-lg p-3 font-mono text-xs space-y-1">
      <.node_view
        scope={@scope}
        target_key={@target_key}
        node={@tree}
        node_key={nil}
        dom_prefix={@dom_prefix}
        editing={@editing}
        edit_value={@edit_value}
        top_level?={true}
      />
    </div>
    """
  end

  @doc """
  Structured/Raw toggle over a config file's raw text — the entry point
  both hosts (`NodeLive.ConfigComponents`, `ProjectLive.Show`) render for
  any `format` with a registered `OrcaHub.ConfigFile` adapter. Structured
  is shown by default when `content` parses; a parse error forces Raw and
  surfaces the error, and disables the Structured button entirely (never
  crashes the host LiveView on malformed content).
  """
  attr :scope, :string, required: true
  attr :target_key, :string, default: ""
  attr :dom_prefix, :string, required: true
  attr :content, :string, required: true
  attr :format, :atom, required: true
  attr :view_mode, :atom, required: true
  attr :editing, :any, default: nil
  attr :edit_value, :string, default: ""

  def structured_or_raw(assigns) do
    assigns = assign(assigns, :parsed, ConfigFile.parse(assigns.format, assigns.content))

    ~H"""
    <div>
      <div class="flex items-center gap-2 mb-2">
        <div class="join">
          <button
            type="button"
            phx-click="toggle_view_mode"
            phx-value-scope={@scope}
            phx-value-key={@target_key}
            phx-value-mode="structured"
            disabled={match?({:error, _}, @parsed)}
            class={["btn btn-xs join-item", structured_active?(@view_mode, @parsed) && "btn-active"]}
          >
            Structured
          </button>
          <button
            type="button"
            phx-click="toggle_view_mode"
            phx-value-scope={@scope}
            phx-value-key={@target_key}
            phx-value-mode="raw"
            class={["btn btn-xs join-item", !structured_active?(@view_mode, @parsed) && "btn-active"]}
          >
            Raw
          </button>
        </div>
        <span :if={match?({:error, _}, @parsed)} class="text-xs text-error">
          Parse error — editing raw text only.
        </span>
      </div>

      <%= if structured_active?(@view_mode, @parsed) do %>
        <% {:ok, tree} = @parsed %>
        <.structured_editor
          scope={@scope}
          target_key={@target_key}
          tree={tree}
          dom_prefix={@dom_prefix}
          editing={@editing}
          edit_value={@edit_value}
        />
      <% else %>
        <div class="bg-base-200 rounded-lg p-3">
          <pre class="text-sm font-mono whitespace-pre-wrap break-words">{@content}</pre>
          <p :if={match?({:error, _}, @parsed)} class="text-xs text-error mt-2 font-mono">
            {parse_error_message(@parsed)}
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  defp structured_active?(:raw, _parsed), do: false
  defp structured_active?(_mode, {:error, _}), do: false
  defp structured_active?(_mode, _parsed), do: true

  defp parse_error_message({:error, reason}) when is_binary(reason), do: reason
  defp parse_error_message({:error, reason}), do: inspect(reason)

  # -------------------------------------------------------------------
  # Recursive node rendering — one clause per tree node `kind`. `<details>`
  # owns its own open/closed state client-side (the template never derives
  # `open` from a changing assign after the initial render), so expanding a
  # section needs no LiveView round trip and survives patches from
  # unrelated edits elsewhere in the tree.
  # -------------------------------------------------------------------

  defp node_view(%{node: %{kind: :object}} = assigns) do
    assigns = assign_new(assigns, :top_level?, fn -> false end)

    ~H"""
    <details open={@top_level?} class="group/details">
      <summary class="group/row cursor-pointer flex items-center gap-1 select-none py-0.5">
        <.icon
          name="hero-chevron-right-micro"
          class="size-3 shrink-0 transition-transform group-open/details:rotate-90"
        />
        <span :if={@node_key != nil} class="text-primary">{@node_key}</span>
        <span class="text-base-content/30">{"{ }"}</span>
        <.delete_button
          :if={!@top_level?}
          scope={@scope}
          target_key={@target_key}
          path={@node.path}
        />
      </summary>
      <div class="pl-4 border-l border-base-300 ml-1.5 mt-1 space-y-0.5">
        <div :for={{key, child} <- @node.entries}>
          <.node_view
            scope={@scope}
            target_key={@target_key}
            node={child}
            node_key={key}
            dom_prefix={@dom_prefix}
            editing={@editing}
            edit_value={@edit_value}
          />
        </div>
        <p :if={@node.entries == []} class="text-base-content/40 italic">(empty)</p>
        <.add_row scope={@scope} target_key={@target_key} path={@node.path} kind={:object} />
      </div>
    </details>
    """
  end

  defp node_view(%{node: %{kind: :array}} = assigns) do
    assigns = assign_new(assigns, :top_level?, fn -> false end)

    ~H"""
    <details open={@top_level?} class="group/details">
      <summary class="group/row cursor-pointer flex items-center gap-1 select-none py-0.5">
        <.icon
          name="hero-chevron-right-micro"
          class="size-3 shrink-0 transition-transform group-open/details:rotate-90"
        />
        <span :if={@node_key != nil} class="text-primary">[{@node_key}]</span>
        <span class="text-base-content/30">[ ]</span>
        <.delete_button
          :if={!@top_level?}
          scope={@scope}
          target_key={@target_key}
          path={@node.path}
        />
      </summary>
      <div class="pl-4 border-l border-base-300 ml-1.5 mt-1 space-y-0.5">
        <div :for={{item, index} <- Enum.with_index(@node.items)}>
          <.node_view
            scope={@scope}
            target_key={@target_key}
            node={item}
            node_key={index}
            dom_prefix={@dom_prefix}
            editing={@editing}
            edit_value={@edit_value}
          />
        </div>
        <p :if={@node.items == []} class="text-base-content/40 italic">(empty)</p>
        <.add_row scope={@scope} target_key={@target_key} path={@node.path} kind={:array} />
      </div>
    </details>
    """
  end

  defp node_view(%{node: %{kind: :leaf}} = assigns) do
    ~H"""
    <div class="group/row relative flex items-center gap-2 py-0.5">
      <span :if={is_integer(@node_key)} class="text-base-content/40">[{@node_key}]</span>
      <span :if={is_binary(@node_key)} class="text-primary">{@node_key}</span>
      <.leaf_value
        scope={@scope}
        target_key={@target_key}
        node={@node}
        dom_prefix={@dom_prefix}
        editing={@editing}
        edit_value={@edit_value}
      />
      <.delete_button scope={@scope} target_key={@target_key} path={@node.path} />
    </div>
    """
  end

  # -------------------------------------------------------------------
  # Leaf value display / inline edit form / boolean toggle
  # -------------------------------------------------------------------

  defp leaf_value(assigns) do
    ~H"""
    <%= if editing_this?(@editing, @scope, @target_key, @node.path) do %>
      <form phx-submit="save_value" class="flex items-center gap-1 flex-1">
        <input type="hidden" name="scope" value={@scope} />
        <input type="hidden" name="key" value={@target_key} />
        <input type="hidden" name="path" value={ConfigFile.encode_path(@node.path)} />
        <input type="hidden" name="value_type" value={@node.value_type} />
        <input
          type="text"
          name="value"
          value={@edit_value}
          class="input input-bordered input-xs flex-1 font-mono"
          phx-hook="AutoFocus"
          id={"#{@dom_prefix}-edit-#{ConfigFile.encode_path(@node.path)}"}
        />
        <button type="submit" class="btn btn-xs btn-primary">Save</button>
        <button
          type="button"
          phx-click="cancel"
          phx-value-scope={@scope}
          phx-value-key={@target_key}
          class="btn btn-xs"
        >
          Cancel
        </button>
      </form>
    <% else %>
      <%= if @node.value_type == :boolean do %>
        <button
          type="button"
          phx-click="save_value"
          phx-value-scope={@scope}
          phx-value-key={@target_key}
          phx-value-path={ConfigFile.encode_path(@node.path)}
          phx-value-value_type="boolean"
          phx-value-value={to_string(!@node.value)}
          class={["badge badge-xs", if(@node.value, do: "badge-success", else: "badge-neutral")]}
        >
          {@node.value}
        </button>
      <% else %>
        <span
          phx-click="edit_value"
          phx-value-scope={@scope}
          phx-value-key={@target_key}
          phx-value-path={ConfigFile.encode_path(@node.path)}
          class={[
            "cursor-pointer rounded px-1 hover:bg-base-300/50 transition-colors",
            value_class(@node.value_type)
          ]}
        >
          {display_value(@node)}
        </span>
      <% end %>
    <% end %>
    """
  end

  defp editing_this?(%{scope: scope, key: key, path: path}, scope, key, path), do: true
  defp editing_this?(_editing, _scope, _key, _path), do: false

  defp display_value(%{value_type: :null}), do: "null"
  defp display_value(%{value_type: :string, value: v}), do: ~s("#{v}")
  defp display_value(%{value: v}), do: to_string(v)

  defp value_class(:string), do: "text-success"
  defp value_class(type) when type in [:integer, :float], do: "text-info"
  defp value_class(:null), do: "italic text-base-content/40"
  defp value_class(_), do: nil

  # -------------------------------------------------------------------
  # Delete button — same hover treatment as BlockEditor's per-block delete.
  # -------------------------------------------------------------------

  defp delete_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="delete_key"
      phx-value-scope={@scope}
      phx-value-key={@target_key}
      phx-value-path={ConfigFile.encode_path(@path)}
      data-confirm="Delete this?"
      class="btn btn-ghost btn-xs opacity-0 group-hover/row:opacity-100 transition-opacity text-error ml-auto"
      title="Delete"
    >
      <.icon name="hero-trash-micro" class="size-3" />
    </button>
    """
  end

  # -------------------------------------------------------------------
  # Always-visible "add" row per object/array level.
  # -------------------------------------------------------------------

  defp add_row(%{kind: :object} = assigns) do
    ~H"""
    <form phx-submit="add_key" class="flex items-center gap-1 mt-1">
      <input type="hidden" name="scope" value={@scope} />
      <input type="hidden" name="key" value={@target_key} />
      <input type="hidden" name="path" value={ConfigFile.encode_path(@path)} />
      <input
        type="text"
        name="name"
        placeholder="key"
        class="input input-bordered input-xs w-28 font-mono"
      />
      <.value_type_select />
      <input
        type="text"
        name="value"
        placeholder="value"
        class="input input-bordered input-xs w-28 font-mono"
      />
      <button type="submit" class="btn btn-xs btn-ghost">+ Add</button>
    </form>
    """
  end

  defp add_row(%{kind: :array} = assigns) do
    ~H"""
    <form phx-submit="add_key" class="flex items-center gap-1 mt-1">
      <input type="hidden" name="scope" value={@scope} />
      <input type="hidden" name="key" value={@target_key} />
      <input type="hidden" name="path" value={ConfigFile.encode_path(@path)} />
      <.value_type_select />
      <input
        type="text"
        name="value"
        placeholder="value"
        class="input input-bordered input-xs w-28 font-mono"
      />
      <button type="submit" class="btn btn-xs btn-ghost">+ Add</button>
    </form>
    """
  end

  defp value_type_select(assigns) do
    ~H"""
    <select name="value_type" class="select select-bordered select-xs">
      <option value="string">string</option>
      <option value="number">number</option>
      <option value="boolean">boolean</option>
      <option value="null">null</option>
    </select>
    """
  end
end
