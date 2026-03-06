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
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/orca_hub"
import topbar from "../vendor/topbar"

let Hooks = {
  ...colocatedHooks,
  Copy: {
    mounted() {
      this.el.addEventListener("phx:copy", () => {
        navigator.clipboard.writeText(this.el.value)
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
          }
        })
      })
    },
    destroyed() {
      window.removeEventListener("keydown", this.handler)
    }
  },
  CopyToClipboard: {
    mounted() {
      this.el.addEventListener("click", () => {
        const text = this.el.dataset.copyText
        if (!text) return
        navigator.clipboard.writeText(text).then(() => {
          this.el.classList.add("text-success")
          setTimeout(() => this.el.classList.remove("text-success"), 1500)
        })
      })
    }
  },
  AutoFocus: {
    mounted() { this.el.focus() },
    updated() { this.el.focus() }
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
    updated() {
      if (this.following) this.scrollToBottom(true)
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
      } else if (this._hadFilter) {
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

