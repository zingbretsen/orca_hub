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
  AutoResize: {
    mounted() {
      this.resize()
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
      if (!this.el.disabled) this.el.focus()
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
    mounted() { this.scrollToBottom() },
    updated() {
      const threshold = 100
      const atBottom = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < threshold
      if (atBottom) this.scrollToBottom()
    },
    scrollToBottom() { this.el.scrollTop = this.el.scrollHeight }
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

