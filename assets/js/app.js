// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
import { TerminalHook } from "./terminal_hook"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/orca_hub"
import topbar from "../vendor/topbar"

// Copy text to the clipboard with a fallback for non-secure contexts (e.g. plain
// HTTP) and stricter browsers (e.g. Edge requiring document focus / transient
// activation). Returns a Promise that resolves on success.
function copyTextToClipboard(text) {
  if (navigator.clipboard?.writeText) {
    return navigator.clipboard.writeText(text).catch(() => legacyCopy(text))
  }
  return legacyCopy(text)
}

function legacyCopy(text) {
  return new Promise((resolve, reject) => {
    const textarea = document.createElement("textarea")
    textarea.value = text
    // Keep it out of view and avoid scrolling/zoom side effects
    textarea.style.position = "fixed"
    textarea.style.top = "-9999px"
    textarea.style.left = "-9999px"
    document.body.appendChild(textarea)
    textarea.select()
    try {
      const ok = document.execCommand("copy")
      ok ? resolve() : reject(new Error("execCommand copy failed"))
    } catch (err) {
      reject(err)
    } finally {
      document.body.removeChild(textarea)
    }
  })
}

let Hooks = {
  ...colocatedHooks,
  Terminal: TerminalHook,
  NodeFilter: {
    mounted() {
      const stored = localStorage.getItem("orca:node_filter")
      const nodes = stored ? JSON.parse(stored) : []
      this.pushEvent("node_filter_init", { nodes })

      this.handleEvent("node_filter_updated", ({ nodes }) => {
        if (nodes.length === 0) {
          localStorage.removeItem("orca:node_filter")
        } else {
          localStorage.setItem("orca:node_filter", JSON.stringify(nodes))
        }
      })

      this.el.addEventListener("dblclick", (e) => {
        const btn = e.target.closest("[data-solo-node]")
        if (btn) {
          e.preventDefault()
          e.stopPropagation()
          this.pushEvent("solo_node_filter", { node: btn.dataset.soloNode })
        }
      })
    }
  },
  ResizeHandle: {
    mounted() {
      this._setupResize()
    },
    updated() {
      // Re-apply saved ratio after LiveView patches reset inline styles
      this._applyRatio()
    },
    destroyed() {
      if (this._cleanup) this._cleanup()
    },
    _setupResize() {
      const container = this.el.parentElement
      let dragging = false
      // Store ratio as fraction of container width for the left panel
      this._ratio = null

      const getPanels = () => {
        const left = container.querySelector("[data-resize-panel='left']")
        const right = container.querySelector("[data-resize-panel='right']")
        return (left && right) ? { left, right } : null
      }

      const applySize = (panels, ratio) => {
        const rect = container.getBoundingClientRect()
        const gap = 16
        const leftWidth = Math.round(ratio * (rect.width - gap))
        const rightWidth = rect.width - gap - leftWidth
        panels.left.style.flex = "none"
        panels.left.style.width = leftWidth + "px"
        panels.right.style.flex = "none"
        panels.right.style.width = rightWidth + "px"
      }

      this._applyRatio = () => {
        if (this._ratio == null) return
        const panels = getPanels()
        if (panels) {
          applySize(panels, this._ratio)
          window.dispatchEvent(new Event("resize"))
        }
      }

      const onMouseDown = (e) => {
        e.preventDefault()
        dragging = true
        document.body.style.cursor = "col-resize"
        document.body.style.userSelect = "none"
      }

      const onMouseMove = (e) => {
        if (!dragging) return
        const panels = getPanels()
        if (!panels) return

        const rect = container.getBoundingClientRect()
        const x = e.clientX - rect.left
        const gap = 16
        const minPx = 300
        const leftWidth = Math.max(minPx, Math.min(x, rect.width - minPx - gap))

        this._ratio = leftWidth / (rect.width - gap)
        applySize(panels, this._ratio)
        window.dispatchEvent(new Event("resize"))
      }

      const onMouseUp = () => {
        if (!dragging) return
        dragging = false
        document.body.style.cursor = ""
        document.body.style.userSelect = ""
      }

      this.el.addEventListener("mousedown", onMouseDown)
      document.addEventListener("mousemove", onMouseMove)
      document.addEventListener("mouseup", onMouseUp)

      // Re-apply ratio after LiveView DOM patches (which reset inline styles)
      this._observer = new MutationObserver(() => {
        if (this._ratio != null && !dragging) {
          const panels = getPanels()
          if (panels && !panels.left.style.width) {
            requestAnimationFrame(() => this._applyRatio())
          }
        }
      })
      this._observer.observe(container, { childList: true, subtree: true, attributes: true, attributeFilter: ["style"] })

      this._cleanup = () => {
        this.el.removeEventListener("mousedown", onMouseDown)
        document.removeEventListener("mousemove", onMouseMove)
        document.removeEventListener("mouseup", onMouseUp)
        if (this._observer) this._observer.disconnect()
      }
    }
  },
  Copy: {
    mounted() {
      this.el.addEventListener("phx:copy", () => {
        copyTextToClipboard(this.el.value)
      })
    }
  },
  CommandPalette: {
    mounted() {
      this.handler = (e) => {
        if ((e.metaKey || e.ctrlKey) && e.key === "k") {
          e.preventDefault()
          e.stopPropagation()
          this.pushEventTo(this.el, "toggle", {})
          return
        }

        // Only handle other keys when the palette is open
        const results = this.el.querySelector("#command-palette-results")
        if (!results) return

        if (e.key === "Escape") {
          e.preventDefault()
          this.pushEventTo(this.el, "close", {})
        } else if (e.key === "ArrowDown") {
          e.preventDefault()
          this.pushEventTo(this.el, "move", {direction: "down"})
        } else if (e.key === "ArrowUp") {
          e.preventDefault()
          this.pushEventTo(this.el, "move", {direction: "up"})
        } else if (e.key === "Enter") {
          e.preventDefault()
          this.pushEventTo(this.el, "go", {})
        } else if (e.key === "Backspace") {
          const input = this.el.querySelector("#command-palette-input")
          if (input && input.value === "") {
            this.pushEventTo(this.el, "back", {})
          }
        }
      }
      window.addEventListener("keydown", this.handler)

      this.toggleHandler = () => this.pushEventTo(this.el, "toggle", {})
      document.addEventListener("command-palette:toggle", this.toggleHandler)

      this.handleEvent("focus-command-palette", () => {
        requestAnimationFrame(() => {
          const input = this.el.querySelector("#command-palette-input")
          if (input) input.focus()
        })
      })

      this.handleEvent("clear-command-palette-input", () => {
        requestAnimationFrame(() => {
          const input = this.el.querySelector("#command-palette-input")
          if (input) {
            input.value = ""
            input.focus()
            // Dispatch a synthetic keyup to reset the debounced phx-keyup search
            // event, preventing a stale query from overwriting the new phase's results
            input.dispatchEvent(new KeyboardEvent("keyup", { bubbles: true }))
          }
        })
      })
    },
    destroyed() {
      window.removeEventListener("keydown", this.handler)
      document.removeEventListener("command-palette:toggle", this.toggleHandler)
    }
  },
  CopyToClipboard: {
    mounted() {
      this.el.addEventListener("click", () => {
        const text = this.el.dataset.copyText
        if (!text) return
        copyTextToClipboard(text).then(() => {
          this.el.classList.add("text-success")
          setTimeout(() => this.el.classList.remove("text-success"), 1500)
        }).catch(() => {})
      })
    }
  },
  AutoFocus: {
    mounted() { this.el.focus() },
    updated() { this.el.focus() }
  },
  ScrollToLine: {
    mounted() { this.scrollToTarget() },
    updated() { this.scrollToTarget() },
    scrollToTarget() {
      const line = this.el.dataset.line
      if (!line) return
      const prefix = this.el.id.includes("mobile") ? "mobile-" : ""
      const isBlock = this.el.id.includes("block")
      const targetId = isBlock ? `${prefix}file-block-${line}` : `${prefix}file-line-${line}`
      const target = this.el.querySelector(`#${targetId}`)
      if (target) {
        requestAnimationFrame(() => {
          target.scrollIntoView({ behavior: "smooth", block: "center" })
        })
      }
    }
  },
  // Session tree page (/sessions/tree): message-edge chips dispatch a
  // "orca:scroll-to-session" custom event (via JS.dispatch, detail: {id})
  // at this hook's element (the tree's root container, mounted once) —
  // scroll the target node into view and briefly flash a highlight ring,
  // matching CopyToClipboard's flash-then-remove-class pattern above.
  ScrollHighlightTarget: {
    mounted() {
      this.el.addEventListener("orca:scroll-to-session", (e) => {
        const id = e.detail && e.detail.id
        if (!id) return
        const target = document.getElementById(`session-node-${id}`)
        if (!target) return
        target.scrollIntoView({ behavior: "smooth", block: "center" })
        target.classList.add("ring", "ring-primary", "ring-offset-2")
        setTimeout(() => target.classList.remove("ring", "ring-primary", "ring-offset-2"), 1500)
      })
    }
  },
  AutoResize: {
    mounted() {
      this.resize()
      this.el.focus()
      this.el.addEventListener("input", () => this.resize())
      this.el.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && (e.ctrlKey || e.metaKey || e.shiftKey)) {
          e.preventDefault()
          this.el.closest("form").dispatchEvent(new Event("submit", {bubbles: true, cancelable: true}))
        }
      })
      this.handleEvent("clear-prompt", () => {
        this.el.value = ""
        this.resize()
        this.el.focus()
      })
    },
    updated() {
      this.el.focus()
    },
    resize() {
      this.el.style.height = "auto"
      this.el.style.height = this.el.scrollHeight + "px"
    }
  },
  Autocomplete: {
    mounted() {
      this.dropdown = document.getElementById("autocomplete-dropdown")
      this.selectedIndex = 0
      this.items = []
      this.trigger = null
      this.triggerPos = 0
      this.debounceTimer = null

      // Initialize textarea resize (same as AutoResize hook)
      this.resize()
      this.el.focus()

      this.el.addEventListener("input", (e) => {
        this.resize()
        this.onInput(e)
      })
      this.el.addEventListener("keydown", (e) => {
        // Handle Ctrl/Cmd+Enter or Shift+Enter to submit (from AutoResize)
        if (e.key === "Enter" && (e.ctrlKey || e.metaKey || e.shiftKey)) {
          e.preventDefault()
          this.el.closest("form").dispatchEvent(new Event("submit", {bubbles: true, cancelable: true}))
          return
        }
        this.onKeydown(e)
      })
      this.el.addEventListener("blur", () => {
        // Delay hide to allow click on dropdown items
        setTimeout(() => this.hideDropdown(), 150)
      })

      this.handleEvent("clear-prompt", () => {
        this.el.value = ""
        this.resize()
        this.el.focus()
        this.hideDropdown()
      })

      this.handleEvent("autocomplete_results", ({ items, type }) => {
        this.items = items || []
        this.selectedIndex = 0
        if (this.items.length > 0) {
          this.showDropdown(type)
        } else {
          this.hideDropdown()
        }
      })
    },

    updated() {
      this.el.focus()
    },

    resize() {
      this.el.style.height = "auto"
      this.el.style.height = this.el.scrollHeight + "px"
    },

    onInput(e) {
      const value = this.el.value
      const cursorPos = this.el.selectionStart

      // Clear pending debounce
      if (this.debounceTimer) clearTimeout(this.debounceTimer)

      // Check for triggers at cursor position
      const beforeCursor = value.substring(0, cursorPos)

      // Check for /command at start of message
      if (beforeCursor.startsWith("/") && !beforeCursor.includes(" ")) {
        this.trigger = "/"
        this.triggerPos = 0
        const query = beforeCursor.substring(1)
        this.debounceTimer = setTimeout(() => {
          this.pushEvent("autocomplete", { type: "command", query })
        }, 50)
        return
      }

      // Check for ## (project) - must check before # (session)
      const projectMatch = beforeCursor.match(/##(\S*)$/)
      if (projectMatch) {
        this.trigger = "##"
        this.triggerPos = cursorPos - projectMatch[0].length
        const query = projectMatch[1]
        this.debounceTimer = setTimeout(() => {
          this.pushEvent("autocomplete", { type: "project", query })
        }, 150)
        return
      }

      // Check for # (session)
      const sessionMatch = beforeCursor.match(/#(\S*)$/)
      if (sessionMatch && !beforeCursor.match(/##\S*$/)) {
        this.trigger = "#"
        this.triggerPos = cursorPos - sessionMatch[0].length
        const query = sessionMatch[1]
        this.debounceTimer = setTimeout(() => {
          this.pushEvent("autocomplete", { type: "session", query })
        }, 150)
        return
      }

      // Check for @ (file)
      const fileMatch = beforeCursor.match(/@(\S*)$/)
      if (fileMatch) {
        this.trigger = "@"
        this.triggerPos = cursorPos - fileMatch[0].length
        const query = fileMatch[1]
        this.debounceTimer = setTimeout(() => {
          this.pushEvent("autocomplete", { type: "file", query })
        }, 150)
        return
      }

      // No trigger found
      this.hideDropdown()
    },

    onKeydown(e) {
      if (!this.dropdown || this.dropdown.classList.contains("hidden")) return

      if (e.key === "ArrowDown") {
        e.preventDefault()
        this.selectedIndex = Math.min(this.selectedIndex + 1, this.items.length - 1)
        this.renderDropdown()
      } else if (e.key === "ArrowUp") {
        e.preventDefault()
        this.selectedIndex = Math.max(this.selectedIndex - 1, 0)
        this.renderDropdown()
      } else if (e.key === "Enter" || e.key === "Tab") {
        if (this.items.length > 0) {
          e.preventDefault()
          this.selectItem(this.items[this.selectedIndex])
        }
      } else if (e.key === "Escape") {
        e.preventDefault()
        this.hideDropdown()
      }
    },

    selectItem(item) {
      if (!item) return

      const value = this.el.value
      const cursorPos = this.el.selectionStart
      const beforeTrigger = value.substring(0, this.triggerPos)
      const afterCursor = value.substring(cursorPos)

      let insertion = item.value
      // Add a space after the insertion if there isn't one
      if (!afterCursor.startsWith(" ") && !afterCursor.startsWith("\n")) {
        insertion += " "
      }

      // For commands, replace from start
      if (this.trigger === "/") {
        this.el.value = insertion + afterCursor
        this.el.selectionStart = this.el.selectionEnd = insertion.length
      } else {
        this.el.value = beforeTrigger + insertion + afterCursor
        this.el.selectionStart = this.el.selectionEnd = beforeTrigger.length + insertion.length
      }

      // Trigger resize and hide dropdown
      this.el.dispatchEvent(new Event("input", { bubbles: true }))
      this.hideDropdown()
      this.el.focus()

      // Handle special command actions
      if (this.trigger === "/" && item.action) {
        this.pushEvent("autocomplete_action", { action: item.action })
        // Clear the input since we're executing an action
        this.el.value = ""
        this.el.dispatchEvent(new Event("input", { bubbles: true }))
      }
    },

    showDropdown(type) {
      if (!this.dropdown) return
      this.renderDropdown()
      this.dropdown.classList.remove("hidden")
    },

    hideDropdown() {
      if (!this.dropdown) return
      this.dropdown.classList.add("hidden")
      this.items = []
      this.trigger = null
    },

    renderDropdown() {
      if (!this.dropdown) return

      const typeLabels = {
        "command": "Commands",
        "file": "Files",
        "session": "Sessions",
        "project": "Projects"
      }

      const typeIcons = {
        "command": "hero-command-line",
        "file": "hero-document",
        "session": "hero-chat-bubble-left-right",
        "project": "hero-folder"
      }

      let html = `<div class="px-2 py-1 text-xs text-base-content/50 border-b border-base-300">${typeLabels[this.items[0]?.type] || "Suggestions"}</div>`
      html += '<div class="max-h-48 overflow-y-auto">'

      this.items.forEach((item, idx) => {
        const isSelected = idx === this.selectedIndex
        const bgClass = isSelected ? "bg-primary/10 text-primary" : "hover:bg-base-300/50"
        const icon = item.icon || typeIcons[item.type] || "hero-sparkles"

        html += `
          <button
            type="button"
            class="w-full flex items-center gap-2 px-2 py-1.5 text-sm text-left ${bgClass} transition-colors"
            data-index="${idx}"
          >
            <span class="size-4 shrink-0 opacity-60">
              <svg class="size-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                ${this.getIconPath(icon)}
              </svg>
            </span>
            <span class="flex-1 truncate">${this.escapeHtml(item.label)}</span>
            ${item.hint ? `<span class="text-xs text-base-content/40 truncate">${this.escapeHtml(item.hint)}</span>` : ""}
          </button>
        `
      })

      html += '</div>'
      html += `<div class="flex items-center gap-3 px-2 py-1 border-t border-base-300 text-xs opacity-40">
        <span><kbd class="kbd kbd-xs">↑↓</kbd> navigate</span>
        <span><kbd class="kbd kbd-xs">↵</kbd> select</span>
        <span><kbd class="kbd kbd-xs">esc</kbd> close</span>
      </div>`

      this.dropdown.innerHTML = html

      // Add click handlers
      this.dropdown.querySelectorAll("button[data-index]").forEach(btn => {
        btn.addEventListener("mousedown", (e) => {
          e.preventDefault()
          const idx = parseInt(btn.dataset.index, 10)
          this.selectItem(this.items[idx])
        })
      })
    },

    getIconPath(iconName) {
      // Simple SVG paths for common icons
      const paths = {
        "hero-command-line": '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="m6.75 7.5 3 2.25-3 2.25m4.5 0h3m-9 8.25h13.5A2.25 2.25 0 0 0 21 18V6a2.25 2.25 0 0 0-2.25-2.25H5.25A2.25 2.25 0 0 0 3 6v12a2.25 2.25 0 0 0 2.25 2.25Z"/>',
        "hero-document": '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M19.5 14.25v-2.625a3.375 3.375 0 0 0-3.375-3.375h-1.5A1.125 1.125 0 0 1 13.5 7.125v-1.5a3.375 3.375 0 0 0-3.375-3.375H8.25m2.25 0H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 0 0-9-9Z"/>',
        "hero-chat-bubble-left-right": '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M20.25 8.511c.884.284 1.5 1.128 1.5 2.097v4.286c0 1.136-.847 2.1-1.98 2.193-.34.027-.68.052-1.02.072v3.091l-3-3c-1.354 0-2.694-.055-4.02-.163a2.115 2.115 0 0 1-.825-.242m9.345-8.334a2.126 2.126 0 0 0-.476-.095 48.64 48.64 0 0 0-8.048 0c-1.131.094-1.976 1.057-1.976 2.192v4.286c0 .837.46 1.58 1.155 1.951m9.345-8.334V6.637c0-1.621-1.152-3.026-2.76-3.235A48.455 48.455 0 0 0 11.25 3c-2.115 0-4.198.137-6.24.402-1.608.209-2.76 1.614-2.76 3.235v6.226c0 1.621 1.152 3.026 2.76 3.235.577.075 1.157.14 1.74.194V21l4.155-4.155"/>',
        "hero-folder": '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M2.25 12.75V12A2.25 2.25 0 0 1 4.5 9.75h15A2.25 2.25 0 0 1 21.75 12v.75m-8.69-6.44-2.12-2.12a1.5 1.5 0 0 0-1.061-.44H4.5A2.25 2.25 0 0 0 2.25 6v12a2.25 2.25 0 0 0 2.25 2.25h15A2.25 2.25 0 0 0 21.75 18V9a2.25 2.25 0 0 0-2.25-2.25h-5.379a1.5 1.5 0 0 1-1.06-.44Z"/>',
        "hero-sparkles": '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M9.813 15.904 9 18.75l-.813-2.846a4.5 4.5 0 0 0-3.09-3.09L2.25 12l2.846-.813a4.5 4.5 0 0 0 3.09-3.09L9 5.25l.813 2.846a4.5 4.5 0 0 0 3.09 3.09L15.75 12l-2.846.813a4.5 4.5 0 0 0-3.09 3.09ZM18.259 8.715 18 9.75l-.259-1.035a3.375 3.375 0 0 0-2.455-2.456L14.25 6l1.036-.259a3.375 3.375 0 0 0 2.455-2.456L18 2.25l.259 1.035a3.375 3.375 0 0 0 2.456 2.456L21.75 6l-1.035.259a3.375 3.375 0 0 0-2.456 2.456ZM16.894 20.567 16.5 21.75l-.394-1.183a2.25 2.25 0 0 0-1.423-1.423L13.5 18.75l1.183-.394a2.25 2.25 0 0 0 1.423-1.423l.394-1.183.394 1.183a2.25 2.25 0 0 0 1.423 1.423l1.183.394-1.183.394a2.25 2.25 0 0 0-1.423 1.423Z"/>',
        "hero-check": '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="m4.5 12.75 6 6 9-13.5"/>',
        "hero-plus-circle": '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M12 9v6m3-3H9m12 0a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"/>',
        "hero-trash": '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="m14.74 9-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 0 1-2.244 2.077H8.084a2.25 2.25 0 0 1-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 0 0-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 0 1 3.478-.397m7.5 0v-.916c0-1.18-.91-2.164-2.09-2.201a51.964 51.964 0 0 0-3.32 0c-1.18.037-2.09 1.022-2.09 2.201v.916m7.5 0a48.667 48.667 0 0 0-7.5 0"/>',
        "hero-cpu-chip": '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M8.25 3v1.5M4.5 8.25H3m18 0h-1.5M4.5 12H3m18 0h-1.5m-15 3.75H3m18 0h-1.5M8.25 19.5V21M12 3v1.5m0 15V21m3.75-18v1.5m0 15V21m-9-1.5h10.5a2.25 2.25 0 0 0 2.25-2.25V6.75a2.25 2.25 0 0 0-2.25-2.25H6.75A2.25 2.25 0 0 0 4.5 6.75v10.5a2.25 2.25 0 0 0 2.25 2.25Zm.75-12h9v9h-9v-9Z"/>'
      }
      return paths[iconName] || paths["hero-sparkles"]
    },

    escapeHtml(text) {
      const div = document.createElement("div")
      div.textContent = text
      return div.innerHTML
    }
  },
  DropTarget: {
    mounted() {
      const imageTypes = ["image/jpeg", "image/png", "image/gif", "image/webp"]
      let dragCount = 0
      const overlay = this.el.querySelector("[data-drop-overlay]")

      this.el.addEventListener("dragenter", (e) => {
        e.preventDefault()
        dragCount++
        if (overlay) overlay.classList.remove("hidden")
      })

      this.el.addEventListener("dragover", (e) => {
        e.preventDefault()
      })

      this.el.addEventListener("dragleave", (e) => {
        e.preventDefault()
        dragCount--
        if (dragCount <= 0) {
          dragCount = 0
          if (overlay) overlay.classList.add("hidden")
        }
      })

      this.el.addEventListener("drop", (e) => {
        e.preventDefault()
        dragCount = 0
        if (overlay) overlay.classList.add("hidden")

        const files = Array.from(e.dataTransfer.files)
        const images = files.filter(f => imageTypes.includes(f.type))
        const others = files.filter(f => !imageTypes.includes(f.type))

        if (images.length > 0) this.upload("image", images)
        if (others.length > 0) this.upload("file", others)
      })
    }
  },
  ScrollToBottom: {
    mounted() {
      this.following = true
      this.scrollToBottom(false)

      // When the user scrolls, check if they're at the bottom to toggle follow mode
      this.el.addEventListener("scroll", () => {
        const threshold = 30
        const atBottom = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < threshold
        this.following = atBottom
      })

      this.handleEvent("tts-autoplay", () => {
        // Small delay to ensure LiveView has patched the DOM and hooks are mounted
        setTimeout(() => {
          const players = this.el.querySelectorAll("[phx-hook='TTSPlayer']")
          if (players.length > 0) {
            const last = players[players.length - 1]
            const toggleBtn = last.querySelector("[data-tts-action='toggle']")
            if (toggleBtn) toggleBtn.click()
          }
        }, 200)
      })
    },
    beforeUpdate() {
      this._prevScrollTop = this.el.scrollTop
      this._prevScrollHeight = this.el.scrollHeight
      // Freeze scroll position during DOM patch to prevent reflow flash
      this.el.style.overflowY = "hidden"
    },
    updated() {
      const newContent = this.el.scrollHeight !== this._prevScrollHeight
      // Restore overflow immediately
      this.el.style.overflowY = "auto"

      if (this.following) {
        // Instant for layout shifts, smooth for new messages
        this.scrollToBottom(newContent)
      } else {
        this.el.scrollTop = this._prevScrollTop
      }
    },
    scrollToBottom(smooth) {
      this.el.scrollTo({
        top: this.el.scrollHeight,
        behavior: smooth ? "smooth" : "instant"
      })
    }
  },

  TTSPlayer: {
    mounted() {
      this.audio = null
      this.chunks = []
      this.currentIndex = 0
      this.playing = false
      this.audioCache = {}
      this.abortController = null

      this.el.addEventListener("click", (e) => {
        const action = e.target.closest("[data-tts-action]")?.dataset.ttsAction
        if (action === "toggle") this.toggle()
        else if (action === "prev") this.prev()
        else if (action === "next") this.next()
        else if (action === "stop") this.stop()
      })

      // Auto-start if flagged for autoplay
      if (this.el.hasAttribute("data-tts-autoplay")) {
        this.start()
      }
    },

    destroyed() {
      this.stop()
    },

    splitIntoChunks(text) {
      // Split on sentence-ending punctuation followed by whitespace
      const raw = text.split(/(?<=[.!?])\s+/)
      const minChars = 80
      const chunks = []
      let buffer = ""

      for (const sentence of raw) {
        if (buffer) {
          buffer += " " + sentence
        } else {
          buffer = sentence
        }
        if (buffer.length >= minChars) {
          chunks.push(buffer.trim())
          buffer = ""
        }
      }
      if (buffer.trim()) {
        // Merge remainder into last chunk if it's too short, otherwise add as new chunk
        if (chunks.length > 0 && buffer.trim().length < minChars) {
          chunks[chunks.length - 1] += " " + buffer.trim()
        } else {
          chunks.push(buffer.trim())
        }
      }
      return chunks
    },

    extractText() {
      // Get the text content from the adjacent message bubble
      const bubble = this.el.closest("[data-tts-container]")?.querySelector("[data-tts-text]")
      if (!bubble) return ""
      return this.cleanTextForTTS(bubble.innerText || "")
    },

    cleanTextForTTS(text) {
      // Strip markdown artifacts that innerText might preserve
      text = text.replace(/^#{1,6}\s+/gm, "")          // markdown headers
      text = text.replace(/```[\s\S]*?```/g, "")        // code blocks
      text = text.replace(/`([^`]+)`/g, "$1")           // inline code (keep content)

      // Elixir/programming term pronunciations (run BEFORE path/hash replacements)
      const termMap = {
        "HEEx": "heeks",
        "EEx": "eeks",
        "heex": "heeks",
        "eex": "eeks",
        "defp": "def p",
        "defmodule": "def module",
        "GenServer": "gen server",
        "PubSub": "pub sub",
        "LiveView": "live view",
        "ExUnit": "ex unit",
        "iex": "I E X",
        "CSRF": "C S R F",
        "JSONL": "JSON lines",
        "nginx": "engine x",
        "stdin": "standard in",
        "stdout": "standard out",
        "stderr": "standard error",
        "CLI": "C L I",
        "OTP": "O T P",
        "npm": "N P M",
        "UUID": "U U I D",
        "regex": "regex",
        "phx": "phoenix",
      }

      for (const [term, replacement] of Object.entries(termMap)) {
        text = text.replace(new RegExp(`\\b${term}\\b`, "g"), replacement)
      }

      // Symbols
      text = text.replace(/->/g, " to ")

      // File paths with directories: extract just the filename
      text = text.replace(/(?:\/[\w.-]+)+\/([\w.-]+)/g, (match, filename) => {
        return filename
          .replace(/_/g, " ")
          .replace(/\.(\w+)$/, " dot $1")
      })

      // Standalone filenames (word.ext): "show.ex" -> "show dot ex"
      text = text.replace(/\b(\w[\w-]*)\.(ex|exs|js|ts|css|html|json|md|yml|yaml|toml|txt|rb|py|go|rs|sh|heex|eex|leex)\b/g,
        (match, name, ext) => `${name.replace(/_/g, " ")} dot ${ext}`
      )

      // Remaining underscores to spaces (variable names etc.)
      text = text.replace(/_/g, " ")

      // Clean up excessive whitespace
      text = text.replace(/\n{2,}/g, ". ")
      text = text.replace(/\s+/g, " ")

      return text.trim()
    },

    toggle() {
      if (this.playing) {
        this.pause()
      } else if (this.chunks.length > 0) {
        this.resume()
      } else {
        this.start()
      }
    },

    start() {
      const text = this.extractText()
      if (!text) return

      this.chunks = this.splitIntoChunks(text)
      if (this.chunks.length === 0) return

      this.currentIndex = 0
      this.playing = true
      this.updateUI()
      this.playCurrentChunk()
    },

    pause() {
      this.playing = false
      if (this.audio) {
        this.audio.pause()
      }
      this.updateUI()
    },

    resume() {
      this.playing = true
      if (this.audio) {
        this.audio.play()
      } else {
        this.playCurrentChunk()
      }
      this.updateUI()
    },

    stop() {
      this.playing = false
      if (this.audio) {
        this.audio.pause()
        this.audio = null
      }
      if (this.abortController) {
        this.abortController.abort()
        this.abortController = null
      }
      this.chunks = []
      this.currentIndex = 0
      this.audioCache = {}
      this.updateUI()
    },

    prev() {
      if (this.currentIndex > 0) {
        if (this.audio) { this.audio.pause(); this.audio = null }
        this.currentIndex--
        this.updateUI()
        if (this.playing) this.playCurrentChunk()
      }
    },

    next() {
      if (this.currentIndex < this.chunks.length - 1) {
        if (this.audio) { this.audio.pause(); this.audio = null }
        this.currentIndex++
        this.updateUI()
        if (this.playing) this.playCurrentChunk()
      } else {
        this.stop()
      }
    },

    async fetchAudio(index) {
      if (this.audioCache[index]) return this.audioCache[index]
      if (index >= this.chunks.length) return null

      const text = this.chunks[index]
      this.abortController = new AbortController()

      const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
      const resp = await fetch("/api/tts", {
        method: "POST",
        headers: { "content-type": "application/json", "x-csrf-token": csrfToken },
        body: JSON.stringify({ text }),
        signal: this.abortController.signal
      })

      if (!resp.ok) throw new Error(`TTS failed: ${resp.status}`)

      const blob = await resp.blob()
      const url = URL.createObjectURL(blob)
      this.audioCache[index] = url
      return url
    },

    async playCurrentChunk() {
      try {
        const url = await this.fetchAudio(this.currentIndex)
        if (!url || !this.playing) return

        this.audio = new Audio()
        this.audio.preload = "auto"
        this.audio.addEventListener("ended", () => {
          if (this.currentIndex < this.chunks.length - 1) {
            this.currentIndex++
            this.updateUI()
            this.playCurrentChunk()
          } else {
            this.stop()
          }
        })
        this.audio.addEventListener("canplaythrough", () => {
          if (this.playing) this.audio.play()
        }, { once: true })
        this.audio.src = url

        // Pre-fetch next chunk
        if (this.currentIndex + 1 < this.chunks.length) {
          this.fetchAudio(this.currentIndex + 1).catch(() => {})
        }
      } catch (e) {
        if (e.name !== "AbortError") console.error("TTS playback error:", e)
        this.stop()
      }
    },

    updateUI() {
      const controls = this.el.querySelector("[data-tts-controls]")
      const playBtn = this.el.querySelector("[data-tts-action='toggle']")

      if (this.chunks.length === 0) {
        if (controls) controls.classList.add("hidden")
        if (playBtn) playBtn.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" class="size-4" viewBox="0 0 20 20" fill="currentColor"><path d="M6.3 2.84A1.5 1.5 0 004 4.11v11.78a1.5 1.5 0 002.3 1.27l9.344-5.891a1.5 1.5 0 000-2.538L6.3 2.84z"/></svg>`
      } else {
        if (controls) controls.classList.remove("hidden")
        const counter = this.el.querySelector("[data-tts-counter]")
        if (counter) counter.textContent = `${this.currentIndex + 1}/${this.chunks.length}`

        if (playBtn) {
          playBtn.innerHTML = this.playing
            ? `<svg xmlns="http://www.w3.org/2000/svg" class="size-4" viewBox="0 0 20 20" fill="currentColor"><path d="M5.75 3a.75.75 0 00-.75.75v12.5c0 .414.336.75.75.75h1.5a.75.75 0 00.75-.75V3.75A.75.75 0 007.25 3h-1.5zM12.75 3a.75.75 0 00-.75.75v12.5c0 .414.336.75.75.75h1.5a.75.75 0 00.75-.75V3.75a.75.75 0 00-.75-.75h-1.5z"/></svg>`
            : `<svg xmlns="http://www.w3.org/2000/svg" class="size-4" viewBox="0 0 20 20" fill="currentColor"><path d="M6.3 2.84A1.5 1.5 0 004 4.11v11.78a1.5 1.5 0 002.3 1.27l9.344-5.891a1.5 1.5 0 000-2.538L6.3 2.84z"/></svg>`
        }
      }
    }
  },

  FileTree: {
    _getVisibleItems() {
      return Array.from(this.el.querySelectorAll("li > button[phx-click='select_file'], li > details > summary"))
    },
    _focusItem(item) {
      if (!item) return
      // Remove highlight from previous
      this.el.querySelectorAll(".file-tree-focused").forEach(el => el.classList.remove("file-tree-focused"))
      item.classList.add("file-tree-focused")
      item.scrollIntoView({ block: "nearest" })
    },
    mounted() {
      this.el.addEventListener("phx:expand-all", () => {
        this.el.querySelectorAll("details").forEach(d => d.open = true)
      })
      this.el.addEventListener("phx:collapse-all", () => {
        this.el.querySelectorAll("details").forEach(d => d.open = false)
      })

      // Tab from search input focuses first tree item
      const search = document.getElementById("file-tree-search")
      if (search) {
        search.addEventListener("keydown", (e) => {
          if (e.key === "Tab") {
            e.preventDefault()
            const items = this._getVisibleItems()
            if (items.length > 0) {
              this._focusItem(items[0])
              this._focusedIndex = 0
              this.el.focus()
            }
          }
        })
      }

      // Make the tree container focusable for keyboard nav
      this.el.setAttribute("tabindex", "-1")
      this.el.style.outline = "none"

      this.el.addEventListener("keydown", (e) => {
        const items = this._getVisibleItems()
        if (items.length === 0) return
        if (this._focusedIndex == null) this._focusedIndex = -1

        if (e.key === "j" || e.key === "ArrowDown") {
          e.preventDefault()
          this._focusedIndex = Math.min(this._focusedIndex + 1, items.length - 1)
          this._focusItem(items[this._focusedIndex])
        } else if (e.key === "k" || e.key === "ArrowUp") {
          e.preventDefault()
          this._focusedIndex = Math.max(this._focusedIndex - 1, 0)
          this._focusItem(items[this._focusedIndex])
        } else if (e.key === "Enter") {
          e.preventDefault()
          const item = items[this._focusedIndex]
          if (item) item.click()
        } else if (e.key === "/" || e.key === "Escape") {
          e.preventDefault()
          this.el.querySelectorAll(".file-tree-focused").forEach(el => el.classList.remove("file-tree-focused"))
          this._focusedIndex = null
          const search = document.getElementById("file-tree-search")
          if (search) search.focus()
        }
      })
    },
    beforeUpdate() {
      this._detailsState = Array.from(this.el.querySelectorAll("details")).map(d => d.open)
      this._hadFilter = !!this.el.dataset.filter
    },
    updated() {
      const hasFilter = !!this.el.dataset.filter
      if (hasFilter) {
        this.el.querySelectorAll("details").forEach(d => d.open = true)
      } else if (this._detailsState) {
        this.el.querySelectorAll("details").forEach((d, i) => {
          if (i < this._detailsState.length) d.open = this._detailsState[i]
        })
      }
      // Re-apply focus highlight if index is still valid
      if (this._focusedIndex != null) {
        const items = this._getVisibleItems()
        this._focusedIndex = Math.min(this._focusedIndex, items.length - 1)
        if (this._focusedIndex >= 0) this._focusItem(items[this._focusedIndex])
      }
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
  dom: {
    // Preserve the user-toggled `open` state on <details> elements across
    // LiveView patches. The server never renders `open`, so morphdom would
    // otherwise collapse any expanded <details> (tool results, thinking
    // groups, subagent blocks) whenever the message feed re-renders.
    onBeforeElUpdated(from, to) {
      if (from.nodeName === "DETAILS" && from.hasAttribute("open")) {
        to.setAttribute("open", "")
      }
    },
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

