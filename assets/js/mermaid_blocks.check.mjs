// Standalone checks for mermaid_blocks.js, which turns ```mermaid code blocks
// into diagrams with a lazily loaded renderer. The repo has no JS test runner,
// so this is a plain node script — same convention as panel_layout.check.mjs:
//
//     node assets/js/mermaid_blocks.check.mjs
//
// Exits non-zero on any broken expectation, and is gated by the ExUnit suite
// through test/orca_hub_web/mermaid_blocks_check_test.exs.
//
// It drives the REAL module against a small fake DOM and a hand-fired
// MutationObserver. The point it pins: a page with no mermaid block never
// loads the renderer, and an ordinary patch (a streamed token, a new message
// without a diagram) costs no document-wide query. Source checks pin the root
// layout and the exact version pin. What it cannot see is mermaid itself
// drawing an SVG; that is the browser smoke test in the perf-d report.

import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

import { MERMAID_CODE_SELECTOR, mutationsAddMermaid, startMermaidBlocks, takeMermaidBlocks } from "./mermaid_blocks.js"

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
const settle = () => new Promise((resolve) => setTimeout(resolve, 0))

// --- a fake DOM, just big enough for MERMAID_CODE_SELECTOR -----------------

let queryCount = 0

class FakeText {
  constructor(text) {
    this.nodeType = 3
    this.data = text
    this.parentElement = null
  }
  get textContent() {
    return this.data
  }
}

class FakeElement {
  constructor(doc, tag, className = "") {
    this.nodeType = 1
    this.ownerDocument = doc
    this.localName = tag
    this.className = className
    this.children = []
    this.parentElement = null
    this.dataset = {}
  }
  append(...nodes) {
    for (const n of nodes) {
      n.parentElement = this
      this.children.push(n)
    }
    return this
  }
  get classList() {
    return this.className.split(/\s+/).filter(Boolean)
  }
  get textContent() {
    return this.children.map((c) => c.textContent).join("")
  }
  set textContent(text) {
    this.children = [new FakeText(text)]
  }
  get isConnected() {
    let n = this
    while (n.parentElement) n = n.parentElement
    return n === this.ownerDocument.body
  }
  // Only the selector the module uses: `pre > code.mermaid, pre > code.language-mermaid`.
  matches(selector) {
    if (selector !== MERMAID_CODE_SELECTOR) throw new Error(`fake DOM: unsupported selector ${selector}`)
    return (
      this.localName === "code" &&
      this.parentElement?.localName === "pre" &&
      (this.classList.includes("mermaid") || this.classList.includes("language-mermaid"))
    )
  }
  *descendants() {
    for (const c of this.children) {
      if (c.nodeType !== 1) continue
      yield c
      yield* c.descendants()
    }
  }
  querySelectorAll(selector) {
    queryCount++
    return [...this.descendants()].filter((el) => el.matches(selector))
  }
  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null
  }
  replaceWith(node) {
    const siblings = this.parentElement.children
    siblings[siblings.indexOf(this)] = node
    node.parentElement = this.parentElement
    this.parentElement = null
  }
}

function fakeDocument() {
  const doc = { createElement: (tag) => new FakeElement(doc, tag) }
  doc.body = new FakeElement(doc, "body")
  return doc
}

// What OrcaHubWeb.Markdown renders for a fenced block: the copy wrapper
// around <pre><code class="language-xxx">.
function codeBlock(doc, lang, source) {
  const code = new FakeElement(doc, "code", `language-${lang}`).append(new FakeText(source))
  const pre = new FakeElement(doc, "pre").append(code)
  const wrapper = new FakeElement(doc, "div", "code-copy-wrapper relative").append(
    pre,
    new FakeElement(doc, "button", "copy-code-btn")
  )
  return { wrapper, pre, code }
}

function harness(doc, { failFirstLoad = false } = {}) {
  const h = { loads: 0, runs: [], frames: [], observer: null }
  h.mermaid = { run: ({ nodes }) => h.runs.push(nodes.map((n) => [n.className, n.textContent])) }
  class FakeObserver {
    constructor(cb) {
      this.cb = cb
      h.observer = this
    }
    observe(root, opts) {
      this.root = root
      this.opts = opts
    }
    fire(records) {
      this.cb(records)
    }
  }
  startMermaidBlocks({
    root: doc.body,
    loadMermaid: () => {
      h.loads++
      if (failFirstLoad && h.loads === 1) return Promise.reject(new Error("offline"))
      return Promise.resolve(h.mermaid)
    },
    nextFrame: (cb) => h.frames.push(cb),
    MutationObserverImpl: FakeObserver,
  })
  h.flush = async () => {
    await settle()
    while (h.frames.length) h.frames.shift()()
  }
  return h
}
const added = (...nodes) => ({ type: "childList", addedNodes: nodes })

// --- checks -------------------------------------------------------------

console.log("a page with no mermaid block")
{
  const doc = fakeDocument()
  doc.body.append(codeBlock(doc, "elixir", "IO.puts(1)").wrapper)
  const h = harness(doc)
  await h.flush()
  eq("does not load the renderer", h.loads, 0)
  eq("observes the body's subtree and <code> class changes", h.observer.opts, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["class"],
  })

  queryCount = 0
  const bubble = new FakeElement(doc, "div", "bubble")
  h.observer.fire([added(new FakeText("tok")), added(new FakeText("en"))])
  h.observer.fire([added(bubble)])
  h.observer.fire([added(codeBlock(doc, "js", "1").wrapper)])
  h.observer.fire([{ type: "attributes", target: bubble, addedNodes: [] }])
  await h.flush()
  eq("streamed tokens and non-mermaid patches load nothing", h.loads, 0)
  ok("and query only what they added, never the document", queryCount <= 2)
}

console.log("a mermaid block in the dead render")
{
  const doc = fakeDocument()
  const block = codeBlock(doc, "mermaid", "graph TD; A-->B")
  doc.body.append(block.wrapper)
  const h = harness(doc)
  await settle()
  eq("starts loading the renderer at once", h.loads, 1)
  eq("renders nothing before the next frame", h.runs, [])
  await h.flush()
  eq("swaps the <pre> for a div.mermaid with the source, and runs mermaid on it", h.runs, [
    [["mermaid", "graph TD; A-->B"]],
  ])
  ok("keeps the copy wrapper, as the old renderer did", block.wrapper.children[0].className === "mermaid")
  ok("marks the replaced <pre> as taken", block.pre.dataset.mermaidRendered === "true")
}

console.log("blocks that arrive with patches")
{
  const doc = fakeDocument()
  const h = harness(doc)
  await h.flush()
  eq("nothing loaded before the first block", h.loads, 0)

  const msg1 = new FakeElement(doc, "article").append(codeBlock(doc, "mermaid", "graph LR; X-->Y").wrapper)
  const msg2 = new FakeElement(doc, "article").append(codeBlock(doc, "mermaid", "pie; \"a\": 1").wrapper)
  doc.body.append(msg1, msg2)
  h.observer.fire([added(msg1)])
  h.observer.fire([added(msg2)])
  await h.flush()
  eq("a burst of patches loads the renderer once", h.loads, 1)
  eq("and renders every block in one run", h.runs, [
    [
      ["mermaid", "graph LR; X-->Y"],
      ["mermaid", 'pie; "a": 1'],
    ],
  ])

  const later = codeBlock(doc, "mermaid", "graph TD; Z")
  doc.body.append(later.wrapper)
  h.observer.fire([added(later.pre)])
  await h.flush()
  eq("a later block reuses the loaded renderer", h.loads, 1)
  eq("and is rendered too", h.runs.length, 2)

  // morphdom can morph an existing block's class in place.
  const morphed = codeBlock(doc, "text", "graph TD; M")
  doc.body.append(morphed.wrapper)
  morphed.code.className = "language-mermaid"
  h.observer.fire([{ type: "attributes", target: morphed.code, addedNodes: [] }])
  await h.flush()
  eq("a block whose class changes to language-mermaid is rendered", h.runs[2], [["mermaid", "graph TD; M"]])
}

console.log("a renderer that fails to load")
{
  const doc = fakeDocument()
  doc.body.append(codeBlock(doc, "mermaid", "graph TD; F").wrapper)
  const origError = console.error
  const errors = []
  console.error = (...args) => errors.push(args.join(" "))
  const h = harness(doc, { failFirstLoad: true })
  await h.flush()
  console.error = origError
  eq("renders nothing", h.runs, [])
  ok("logs the failure", errors.some((e) => /mermaid failed to load/.test(e)))
  const next = codeBlock(doc, "mermaid", "graph TD; G")
  doc.body.append(next.wrapper)
  h.observer.fire([added(next.wrapper)])
  await h.flush()
  eq("the next block retries the load", h.loads, 2)
  eq("and renders both blocks", h.runs, [
    [
      ["mermaid", "graph TD; F"],
      ["mermaid", "graph TD; G"],
    ],
  ])
}

console.log("pure helpers")
{
  const doc = fakeDocument()
  const plain = new FakeElement(doc, "code", "language-mermaid")
  ok("a <code> outside a <pre> is not a block", !mutationsAddMermaid([added(plain)]))
  const block = codeBlock(doc, "mermaid", "x")
  ok("an added <pre><code class=language-mermaid> is", mutationsAddMermaid([added(block.pre)]))
  const legacy = new FakeElement(doc, "pre").append(new FakeElement(doc, "code", "mermaid"))
  ok("so is the bare `mermaid` class", mutationsAddMermaid([added(legacy)]))
  const root = new FakeElement(doc, "div").append(block.wrapper)
  eq("takeMermaidBlocks takes a block once", [takeMermaidBlocks(root).length, takeMermaidBlocks(root).length], [1, 0])
}

console.log("source checks")
{
  const root = readFileSync(join(HERE, "../../lib/orca_hub_web/components/layouts/root.html.heex"), "utf8")
  ok("the root layout loads nothing from a CDN", !/cdn\.jsdelivr|https:\/\/[^"]*mermaid/.test(root))
  ok(
    "the root layout publishes the mermaid bundle's URL",
    root.includes('<meta name="orca-lazy:mermaid-js" content={~p"/assets/js/lazy/mermaid.js"} />')
  )
  ok(
    "the root layout still hides a mermaid <pre> until it is rendered",
    root.includes("pre:has(> code.mermaid), pre:has(> code.language-mermaid) { visibility: hidden;")
  )
  const pkg = JSON.parse(readFileSync(join(HERE, "../package.json"), "utf8"))
  ok("mermaid is pinned to an exact version", /^\d+\.\d+\.\d+$/.test(pkg.dependencies.mermaid || ""))
  const app = readFileSync(join(HERE, "app.js"), "utf8")
  ok("app.js starts the block renderer", /startMermaidBlocks\(/.test(app))
  ok("app.js imports no mermaid itself", !/from\s+["']mermaid["']/.test(app))
}

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
