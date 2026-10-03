// Standalone checks for the session page's file-panel layout signal
// (ORCAHUB3-130, panel_layout.js). The repo has no JS test runner, so this is
// a plain node script — same convention as voice_view.check.mjs:
//
//     node assets/js/panel_layout.check.mjs
//
// Exits non-zero on any broken expectation, and is gated by the ExUnit suite
// through test/orca_hub_web/panel_layout_check_test.exs.
//
// It drives the REAL module against a fake matchMedia: the layout the join
// params report, and the hook's push/reconcile/teardown. What it cannot see is
// a browser's actual media evaluation; the breakpoint itself is pinned by
// source checks against the CSS and the template it mirrors.

import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

import { PANEL_LAYOUT_MEDIA, PanelLayoutHook, panelLayout } from "./panel_layout.js"

const HERE = dirname(fileURLToPath(import.meta.url))

let pass = 0,
  fail = 0
const ok = (name, cond) => {
  if (cond) {
    pass++
    console.log(`  ok   ${name}`)
  } else {
    fail++
    console.log(`  FAIL ${name}`)
  }
}
const eq = (name, got, want) => {
  const g = JSON.stringify(got),
    w = JSON.stringify(want)
  if (g === w) {
    pass++
    console.log(`  ok   ${name}`)
  } else {
    fail++
    console.log(`  FAIL ${name}\n       got  ${g}\n       want ${w}`)
  }
}

// A window whose one media query list can be flipped, firing `change` the way
// a browser does when the viewport crosses the breakpoint.
function fakeWindow(matches) {
  const queries = []
  const mql = {
    matches,
    listeners: new Set(),
    addEventListener(type, fn) {
      if (type === "change") this.listeners.add(fn)
    },
    removeEventListener(type, fn) {
      if (type === "change") this.listeners.delete(fn)
    },
    flip(to) {
      this.matches = to
      for (const fn of [...this.listeners]) fn({ matches: to, media: PANEL_LAYOUT_MEDIA })
    },
  }
  return {
    queries,
    mql,
    matchMedia(q) {
      queries.push(q)
      return mql
    },
  }
}

function mountHook(win, serverLayout) {
  globalThis.window = win
  const pushed = []
  const hook = Object.create(PanelLayoutHook)
  hook.el = { dataset: serverLayout ? { panelLayout: serverLayout } : {} }
  hook.pushEvent = (event, payload) => pushed.push([event, payload])
  hook.mounted()
  return { hook, pushed }
}

// ======================================================================
console.log("\n1. the breakpoint mirrors the shells' CSS `lg:`")
{
  eq("Tailwind v4's default lg, as it compiles it", PANEL_LAYOUT_MEDIA, "(width >= 64rem)")

  const css = readFileSync(join(HERE, "../css/app.css"), "utf8")
  ok("app.css does not redefine the lg breakpoint", !/--breakpoint-lg\s*:/.test(css))
  ok("...nor clear the default breakpoints", !/--breakpoint-\*\s*:/.test(css))

  const heex = readFileSync(
    join(HERE, "../../lib/orca_hub_web/live/session_live/show.html.heex"),
    "utf8"
  )
  ok("the desktop shell is shown from lg up", heex.includes('class="hidden lg:flex flex-col min-w-0 w-1/2"'))
  ok("the mobile shell is hidden from lg up", heex.includes('class="lg:hidden voice-view:hidden"'))
  ok("the hook's element is rendered", /id="panel-layout"\s+phx-hook="PanelLayout"/.test(heex))
}

// ======================================================================
console.log("\n2. panelLayout() — the join's connect param")
{
  const wide = fakeWindow(true)
  eq("a wide viewport is desktop", panelLayout(wide), "desktop")
  eq("...asked with the one constant", wide.queries, [PANEL_LAYOUT_MEDIA])
  eq("a narrow viewport is mobile", panelLayout(fakeWindow(false)), "mobile")
  eq("no matchMedia is unknown (the server renders both shells)", panelLayout({}), null)
}

// ======================================================================
console.log("\n3. PanelLayoutHook — breakpoint crossings")
{
  const win = fakeWindow(true)
  const { hook, pushed } = mountHook(win, "desktop")
  eq("no push on mount when the server already has it right", pushed, [])
  eq("listens for change", win.mql.listeners.size, 1)

  win.mql.flip(false)
  eq("narrowing past lg pushes mobile", pushed, [["panel_layout", { layout: "mobile" }]])
  win.mql.flip(true)
  eq("widening back pushes desktop", pushed.at(-1), ["panel_layout", { layout: "desktop" }])

  hook.destroyed()
  eq("destroyed() removes the listener", win.mql.listeners.size, 0)
  win.mql.flip(false)
  eq("...so a later crossing pushes nothing", pushed.length, 2)
}
{
  const { pushed } = mountHook(fakeWindow(false), "desktop")
  eq(
    "mount reconciles a crossing missed between join and mount",
    pushed,
    [["panel_layout", { layout: "mobile" }]]
  )
}
{
  let threw = null
  try {
    const { hook, pushed } = mountHook({}, "desktop")
    hook.destroyed()
    eq("no matchMedia: the hook stays inert", pushed, [])
  } catch (e) {
    threw = e
  }
  ok("...and never throws", threw === null)
}

// ======================================================================
console.log("\n4. app.js wiring (source check)")
{
  const src = readFileSync(join(HERE, "app.js"), "utf8")
  ok("registers the hook as PanelLayout", /PanelLayout:\s*PanelLayoutHook/.test(src))
  ok(
    "params is a function, so every join re-reads the layout",
    /params:\s*\(\)\s*=>\s*\(\{[^}]*panel_layout:\s*panelLayout\(\)/.test(src)
  )
}

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
