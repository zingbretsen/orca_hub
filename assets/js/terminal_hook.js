import { Socket } from "phoenix"
import { lazyLoader } from "./lazy_assets"

// xterm and its stylesheet live in the lazily loaded terminal bundle
// (assets/js/lazy/terminal.js), not in app.js. Both are fetched in parallel on
// the first mount on a page and cached for the rest of it. The stylesheet is
// awaited too, because xterm measures its cells when it opens.
export function loadTerminalBundle(loader = lazyLoader()) {
  return Promise.all([loader.loadModule("terminal-js"), loader.loadStylesheet("terminal-css")]).then(
    ([bundle]) => bundle
  )
}

// xterm hands onData a JS string, and btoa() only takes Latin-1: a typed or
// pasted "é" went over as one byte that is not UTF-8 (garbage in the shell),
// and anything past U+00FF threw. Input is encoded to UTF-8 first.
const utf8 = new TextEncoder()

function bytesToBase64(bytes) {
  let binary = ""
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000))
  }
  return btoa(binary)
}

function base64ToBytes(b64) {
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))
}

// The server debounces too; this keeps a panel drag from sending dozens.
const RESIZE_DEBOUNCE_MS = 150

export const TerminalHook = {
  mounted() {
    const terminalId = this.el.dataset.terminalId
    if (!terminalId) return

    // Clean up any previous connection (guards against double-mount)
    this._cleanup()

    // The hook can be destroyed (or remounted) while the bundle loads. Only
    // the mount that still owns this token may open the terminal.
    const mountToken = {}
    this._mountToken = mountToken
    loadTerminalBundle().then(
      ({ Terminal, FitAddon }) => {
        if (this._mountToken === mountToken) this._open(terminalId, Terminal, FitAddon)
      },
      (err) => {
        console.error("terminal bundle failed to load", err)
        if (this._mountToken === mountToken) {
          this.el.textContent = "[Terminal failed to load. Reload the page to try again.]"
        }
      }
    )
  },

  _open(terminalId, Terminal, FitAddon) {
    // Create xterm.js instance
    this.term = new Terminal({
      cursorBlink: true,
      fontSize: 14,
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
      theme: {
        background: "#1d232a",
        foreground: "#a6adbb",
        cursor: "#a6adbb",
        selectionBackground: "#3b4048",
        black: "#1d232a",
        red: "#f87272",
        green: "#36d399",
        yellow: "#fbbd23",
        blue: "#3abff8",
        magenta: "#d572b7",
        cyan: "#22d3ee",
        white: "#a6adbb",
      },
    })

    this.fitAddon = new FitAddon()
    this.term.loadAddon(this.fitAddon)
    this.term.open(this.el)

    // Prevent the browser from intercepting special keys (Ctrl+C, Escape, etc.)
    // Return true = xterm handles it; false = browser handles it
    this.term.attachCustomKeyEventHandler((ev) => {
      // Let browser handle Ctrl+Shift+C/V (copy/paste with shift) and F5/F12
      if (ev.ctrlKey && ev.shiftKey && (ev.key === "C" || ev.key === "V")) return false
      if (ev.key === "F5" || ev.key === "F12") return false
      // xterm handles everything else: Ctrl+C, Ctrl+D, Ctrl+Z, Escape, arrows, etc.
      return true
    })

    // Wait for fonts before measuring cell width — otherwise the FitAddon
    // measures with fallback metrics and characters land at wrong positions
    // once the real font finally loads.
    const doFit = () => {
      if (this._visible()) {
        this._fitAndReport()
        this.term.focus()
      }
    }

    if (document.fonts && document.fonts.ready) {
      document.fonts.ready.then(doFit)
    } else {
      doFit()
    }

    // Use a shared socket so we don't open multiple WebSocket connections
    if (!window.__terminalSocket) {
      window.__terminalSocket = new Socket("/terminal_socket")
      window.__terminalSocket.connect()
    }
    this.socket = window.__terminalSocket
    // Unique per hook instance: two hooks for the same terminal (e.g. the
    // desktop panel and the CSS-hidden mobile modal both mounting on the
    // same page) must not join the identical topic — Phoenix closes the
    // first channel when a second join for the same topic arrives on the
    // same socket.
    const clientRef = crypto.randomUUID()
    this.channel = this.socket.channel(`terminal:${terminalId}:${clientRef}`)

    this.channel
      .join()
      .receive("ok", (resp) => {
        if (resp.scrollback) {
          const bytes = base64ToBytes(resp.scrollback)
          if (bytes.length > 0) {
            this.term.write(bytes)
          }
        }
        // The pty learns the panel's size on every (re)join; until now it
        // only heard about later resizes.
        this._sentSize = null
        this._fitAndReport()
        // Nothing is running behind this terminal (it stopped while no hook
        // was mounted, e.g. idle teardown behind a closed panel): say so, and
        // let the hosting LiveView offer a restart.
        if (resp.running === false && !this._exited) {
          this._exited = true
          this.term.writeln("\r\n[Terminal is not running]")
          this.pushEvent("terminal_status_changed", { terminal_id: terminalId, status: "stopped" })
        }
      })
      .receive("error", (resp) => {
        this.term.writeln(`\r\n[Connection error: ${resp.reason || "unknown"}]`)
        // A deleted terminal never comes back; stop the channel's rejoin loop.
        if (resp.reason === "not_found" && this.channel) {
          this.channel.leave()
          this.channel = null
        }
      })

    // Server output -> xterm
    this.channel.on("output", ({ data }) => {
      this.term.write(base64ToBytes(data))
    })

    // The hosting LiveView (TerminalLive.Show or the session page's panel)
    // handles both events; the channel stays joined, so a restart of the
    // same terminal streams into this xterm again.
    this.channel.on("exit", ({ code }) => {
      this._exited = true
      this.term.writeln(`\r\n[Process exited with code ${code}]`)
      this.pushEvent("terminal_exited", { terminal_id: terminalId, code })
    })

    this.channel.on("status", ({ status }) => {
      if (status === "running" && this._exited) {
        this._exited = false
        this.term.writeln("\r\n[Shell restarted]")
        // A new runner starts at the row's stored size; send ours.
        this._sentSize = null
        this._reportSize()
      } else if ((status === "stopped" || status === "deleted") && !this._exited) {
        this._exited = true
        this.term.writeln(`\r\n[Terminal ${status}]`)
      }
      this.pushEvent("terminal_status_changed", {
        terminal_id: terminalId,
        status,
      })
    })

    // xterm input -> server. Only from an xterm that is laid out: the
    // session page also mounts a display:none copy of each terminal (the
    // mobile modal on desktop, the desktop panel on mobile), and that copy
    // answers terminal queries (cursor position, device attributes) too, so
    // the shell got every reply twice and printed the extra as junk.
    this.term.onData((data) => {
      if (!this.channel || !this._laidOut()) return
      this.channel.push("input", { data: bytesToBase64(utf8.encode(data)) })
    })

    // Handle resize
    this.resizeObserver = new ResizeObserver(() => this._fitAndReport())
    this.resizeObserver.observe(this.el)

    // Watch for visibility changes (tab switching uses invisible class)
    this.mutationObserver = new MutationObserver(() => {
      if (this._visible()) {
        // Just became visible — re-fit, report and focus
        requestAnimationFrame(() => {
          this._fitAndReport()
          if (this.term) this.term.focus()
        })
      }
    })
    this.mutationObserver.observe(this.el, {
      attributes: true,
      attributeFilter: ["class"],
    })
  },

  destroyed() {
    this._cleanup()
  },

  _laidOut() {
    return this.el.offsetWidth > 0 || this.el.offsetHeight > 0
  },

  _visible() {
    return !this.el.classList.contains("invisible") && this.el.offsetWidth > 0
  },

  // Fit xterm to the element, then tell the pty (debounced, and only when
  // the size changed). Hidden copies never report, so they cannot fight
  // the visible one over the pty's size.
  _fitAndReport() {
    if (!this.term || !this._visible()) return
    this.fitAddon.fit()
    this._reportSize()
  },

  _reportSize() {
    clearTimeout(this._resizeTimer)
    this._resizeTimer = setTimeout(() => {
      if (!this.term || !this.channel || this.channel.state !== "joined") return
      const { cols, rows } = this.term
      const sent = this._sentSize
      if (sent && sent.cols === cols && sent.rows === rows) return
      this._sentSize = { cols, rows }
      this.channel.push("resize", { cols, rows })
    }, RESIZE_DEBOUNCE_MS)
  },

  _cleanup() {
    this._mountToken = null
    clearTimeout(this._resizeTimer)
    if (this.channel) {
      this.channel.leave()
      this.channel = null
    }
    if (this.resizeObserver) {
      this.resizeObserver.disconnect()
      this.resizeObserver = null
    }
    if (this.mutationObserver) {
      this.mutationObserver.disconnect()
      this.mutationObserver = null
    }
    if (this.term) {
      this.term.dispose()
      this.term = null
    }
  },
}
