// Lazy entry (the `orca_hub_lazy` esbuild profile): what the Terminal hook
// needs that is too big for app.js. xterm alone was about half of app.js, on
// every page, for the few pages that show a terminal. terminal_hook.js loads
// this through lazy_assets.js on its first mount.
//
// The CSS import is what makes the stylesheet a build output: esbuild writes
// it next to this entry as terminal.css, and the hook links it before it opens
// a terminal.
import "@xterm/xterm/css/xterm.css"

export { Terminal } from "@xterm/xterm"
export { FitAddon } from "@xterm/addon-fit"
