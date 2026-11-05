// Lazy entry (the `orca_hub_lazy` esbuild profile): the mermaid diagram
// renderer, loaded by mermaid_blocks.js only when a ```mermaid block first
// appears on a page. Pinned exactly in package.json; it used to come from a
// floating `mermaid@11` CDN tag on every page.
import mermaid from "mermaid"

mermaid.initialize({ startOnLoad: false, theme: "dark" })

export default mermaid
