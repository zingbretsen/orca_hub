// Standalone checks for the lazily loaded bundles (lazy_assets.js) and the
// Terminal hook that loads xterm through them (terminal_hook.js). The repo has
// no JS test runner, so this is a plain node script — same convention as
// panel_layout.check.mjs:
//
//     node assets/js/lazy_assets.check.mjs
//
// Exits non-zero on any broken expectation, and is gated by the ExUnit suite
// through test/orca_hub_web/lazy_assets_check_test.exs.
//
// It drives the REAL modules against a fake document. terminal_hook.js imports
// `phoenix` (a mix dep, not an npm package), so a module resolve hook swaps in
// a stub Socket. What this cannot see is a real browser fetching the bundles;
// test/orca_hub_web/asset_bundles_test.exs runs the real esbuild profiles, and
// the browser smoke test is in the perf-d report.

import { registerHooks } from "node:module"

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === "phoenix") {
      return {
        url: "data:text/javascript,export class Socket { connect() {} channel() {} }",
        shortCircuit: true,
      }
    }
    // app.js's modules import each other without an extension (esbuild style).
    if (specifier.startsWith(".") && !/\.[cm]?js$/.test(specifier)) {
      return nextResolve(`${specifier}.js`, context)
    }
    return nextResolve(specifier, context)
  },
})

const { createLazyLoader, lazyAssetUrl } = await import("./lazy_assets.js")
const { TerminalHook } = await import("./terminal_hook.js")

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
const settle = () => new Promise((resolve) => setTimeout(resolve, 0))

// A document with <meta name=... content=...> tags in its head, and <link>s
// whose load/error the test fires by hand, the way a browser would.
function fakeDocument(metas) {
  const head = {
    children: [],
    appendChild(el) {
      this.children.push(el)
      el.parent = this
      return el
    },
  }
  return {
    head,
    metas,
    links: () => head.children.filter((el) => el.tagName === "LINK"),
    querySelector(selector) {
      const m = selector.match(/^meta\[name="(.+)"\]$/)
      if (!m || !(m[1] in metas)) return null
      return { getAttribute: (attr) => (attr === "content" ? metas[m[1]] : null) }
    },
    createElement(tag) {
      const listeners = {}
      return {
        tagName: tag.toUpperCase(),
        addEventListener(type, fn) {
          ;(listeners[type] ||= []).push(fn)
        },
        fire(type) {
          for (const fn of listeners[type] || []) fn({ type })
        },
        remove() {
          const i = this.parent.children.indexOf(this)
          if (i >= 0) this.parent.children.splice(i, 1)
        },
      }
    },
  }
}

const METAS = {
  "orca-lazy:terminal-js": "/assets/js/lazy/terminal-abc123.js?vsn=d",
  "orca-lazy:terminal-css": "/assets/js/lazy/terminal-def456.css?vsn=d",
}

console.log("lazyAssetUrl")
{
  const doc = fakeDocument(METAS)
  eq("reads the URL from the orca-lazy meta tag", lazyAssetUrl("terminal-js", doc), METAS["orca-lazy:terminal-js"])
  let threw = null
  try {
    lazyAssetUrl("nope", doc)
  } catch (err) {
    threw = err
  }
  ok("throws, naming the tag, when the root layout has no such meta", /orca-lazy:nope/.test(String(threw)))
}

console.log("loadModule")
{
  const doc = fakeDocument(METAS)
  const imported = []
  const loader = createLazyLoader({
    doc,
    importModule: (url) => {
      imported.push(url)
      return Promise.resolve({ url })
    },
  })
  const a = loader.loadModule("terminal-js")
  const b = loader.loadModule("terminal-js")
  ok("two callers share one promise", a === b)
  const mod = await a
  eq("imports the meta tag's URL, once", imported, [METAS["orca-lazy:terminal-js"]])
  eq("resolves to the module", mod.url, METAS["orca-lazy:terminal-js"])

  let rejected = null
  await loader.loadModule("missing").catch((err) => (rejected = err))
  ok("a missing meta tag rejects instead of throwing", rejected instanceof Error)
}

{
  const doc = fakeDocument(METAS)
  let calls = 0
  const loader = createLazyLoader({
    doc,
    importModule: () => {
      calls++
      return calls === 1 ? Promise.reject(new Error("network down")) : Promise.resolve({ second: true })
    },
  })
  let failed = false
  await loader.loadModule("terminal-js").catch(() => (failed = true))
  ok("a failed import rejects", failed)
  await settle()
  const retried = await loader.loadModule("terminal-js")
  ok("a failed import is forgotten, so the next caller retries", calls === 2 && retried.second === true)
}

console.log("loadStylesheet")
{
  const doc = fakeDocument(METAS)
  const loader = createLazyLoader({ doc, importModule: () => Promise.resolve({}) })
  const a = loader.loadStylesheet("terminal-css")
  const b = loader.loadStylesheet("terminal-css")
  ok("two callers share one promise", a === b)
  eq("appends one <link rel=stylesheet> to <head>", doc.links().map((l) => [l.rel, l.href]), [
    ["stylesheet", METAS["orca-lazy:terminal-css"]],
  ])
  let resolved = "pending"
  a.then((v) => (resolved = v))
  await settle()
  eq("is still pending before the link loads", resolved, "pending")
  doc.links()[0].fire("load")
  eq("resolves true once the link loads", await a, true)
}

{
  const doc = fakeDocument(METAS)
  const loader = createLazyLoader({ doc, importModule: () => Promise.resolve({}) })
  const origError = console.error
  console.error = () => {}
  const a = loader.loadStylesheet("terminal-css")
  doc.links()[0].fire("error")
  eq("resolves false (never rejects) when the link fails", await a, false)
  eq("removes the failed <link>", doc.links().length, 0)
  loader.loadStylesheet("terminal-css")
  eq("a failed stylesheet is retried by the next caller", doc.links().length, 1)
  eq("a missing meta tag resolves false", await loader.loadStylesheet("missing"), false)
  console.error = origError
}

console.log("TerminalHook")
// The hook uses the page's shared loader, so give the module a global
// document whose bundle URL is a data: module node can really import().
const BUNDLE =
  "data:text/javascript," +
  encodeURIComponent("export class Terminal {}; export class FitAddon {}")
globalThis.document = fakeDocument({
  "orca-lazy:terminal-js": BUNDLE,
  "orca-lazy:terminal-css": "/assets/js/lazy/terminal.css",
})

function mountHook(terminalId) {
  const hook = Object.create(TerminalHook)
  hook.el = { dataset: { terminalId }, textContent: "" }
  hook.opened = []
  hook._open = function (id, Terminal, FitAddon) {
    this.opened.push([id, Terminal.name, FitAddon.name])
  }
  return hook
}
const cssLink = () => globalThis.document.links()[0]

{
  const hook = mountHook("t1")
  hook.mounted()
  await settle()
  eq("does not open the terminal before its stylesheet loads", hook.opened, [])
  eq("links the terminal stylesheet once", globalThis.document.links().length, 1)
  cssLink().fire("load")
  await settle()
  await settle()
  eq("opens the terminal with xterm from the lazy bundle", hook.opened, [["t1", "Terminal", "FitAddon"]])

  const second = mountHook("t2")
  second.mounted()
  await settle()
  await settle()
  eq("a later mount reuses the loaded bundle and stylesheet", second.opened, [["t2", "Terminal", "FitAddon"]])
  eq("still one stylesheet link on the page", globalThis.document.links().length, 1)
}

{
  const hook = mountHook("t3")
  hook.mounted()
  hook.destroyed()
  await settle()
  await settle()
  eq("a hook destroyed while the bundle loads never opens", hook.opened, [])

  const twice = mountHook("t4")
  twice.mounted()
  twice.mounted()
  await settle()
  await settle()
  eq("a double mount opens the terminal once", twice.opened, [["t4", "Terminal", "FitAddon"]])

  const noId = mountHook(undefined)
  noId.mounted()
  await settle()
  eq("an element with no data-terminal-id loads nothing", noId.opened, [])
}

{
  // The page's loader keeps the document it was created with, so point that
  // document's meta tag at a bundle that throws when it is imported.
  globalThis.document.metas["orca-lazy:terminal-js"] =
    "data:text/javascript," + encodeURIComponent("throw new Error('boom')")
  const origError = console.error
  const errors = []
  console.error = (...args) => errors.push(args.join(" "))
  const hook = mountHook("t5")
  hook.mounted()
  await settle()
  await settle()
  console.error = origError
  eq("a bundle that fails to load opens nothing", hook.opened, [])
  ok("tells the user in the terminal's place", /Terminal failed to load/.test(hook.el.textContent))
  ok("logs the failure", errors.some((e) => /terminal bundle failed to load/.test(e)))
}

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
