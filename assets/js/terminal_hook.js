import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import { Socket } from "phoenix"

export const TerminalHook = {
  mounted() {
    const terminalId = this.el.dataset.terminalId
    if (!terminalId) return

    // Clean up any previous connection (guards against double-mount)
    this._cleanup()

    // Create xterm.js instance
    this.term = new Terminal({
      cursorBlink: true,
      fontSize: 14,
      fontFamily: "'JetBrains Mono', 'Fira Code', 'Cascadia Code', Menlo, monospace",
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
    this.fitAddon.fit()

    // Use a shared socket so we don't open multiple WebSocket connections
    if (!window.__terminalSocket) {
      window.__terminalSocket = new Socket("/terminal_socket")
      window.__terminalSocket.connect()
    }
    this.socket = window.__terminalSocket
    this.channel = this.socket.channel(`terminal:${terminalId}`)

    this.channel
      .join()
      .receive("ok", (resp) => {
        if (resp.scrollback) {
          const bytes = Uint8Array.from(atob(resp.scrollback), (c) =>
            c.charCodeAt(0)
          )
          if (bytes.length > 0) {
            this.term.write(bytes)
          }
        }
      })
      .receive("error", (resp) => {
        this.term.writeln(`\r\n[Connection error: ${resp.reason || "unknown"}]`)
      })

    // Server output -> xterm
    this.channel.on("output", ({ data }) => {
      const bytes = Uint8Array.from(atob(data), (c) => c.charCodeAt(0))
      this.term.write(bytes)
    })

    this.channel.on("exit", ({ code }) => {
      this.term.writeln(`\r\n[Process exited with code ${code}]`)
      this.pushEvent("terminal_exited", { terminal_id: terminalId, code })
    })

    this.channel.on("status", ({ status }) => {
      this.pushEvent("terminal_status_changed", {
        terminal_id: terminalId,
        status,
      })
    })

    // xterm input -> server
    this.term.onData((data) => {
      this.channel.push("input", { data: btoa(data) })
    })

    // Handle resize
    this.resizeObserver = new ResizeObserver(() => {
      this.fitAddon.fit()
      if (this.channel && this.channel.state === "joined") {
        this.channel.push("resize", {
          cols: this.term.cols,
          rows: this.term.rows,
        })
      }
    })
    this.resizeObserver.observe(this.el)
  },

  destroyed() {
    this._cleanup()
  },

  _cleanup() {
    if (this.channel) {
      this.channel.leave()
      this.channel = null
    }
    if (this.resizeObserver) {
      this.resizeObserver.disconnect()
      this.resizeObserver = null
    }
    if (this.term) {
      this.term.dispose()
      this.term = null
    }
  },
}
