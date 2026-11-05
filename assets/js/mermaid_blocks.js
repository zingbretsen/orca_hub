// Renders ```mermaid fenced code blocks as diagrams, on every page.
//
// OrcaHubWeb.Markdown (Earmark, `code_class_prefix: "language-"`) emits them
// as <pre><code class="language-mermaid">. The root layout's inline <style>
// keeps such a <pre> hidden until it is replaced by a rendered diagram.
//
// The renderer is the lazily loaded mermaid bundle (assets/js/lazy/mermaid.js),
// imported only when the first mermaid block appears, so a page without one
// fetches nothing. Blocks arrive with the dead render, LiveView patches, stream
// inserts and live navigation, so a MutationObserver watches the body. Its
// callback only looks at what each mutation added (and at class changes on
// <code> elements, for a block morphed in place). The document-wide query
// runs only after a mermaid block was actually seen, not after every patch.
// On Session Show that matters: patches arrive with every streamed token.

export const MERMAID_CODE_SELECTOR = "pre > code.mermaid, pre > code.language-mermaid"

function isMermaidCode(el) {
  return el.localName === "code" && el.matches(MERMAID_CODE_SELECTOR)
}

// Whether any of these MutationRecords could have introduced a mermaid block.
export function mutationsAddMermaid(records) {
  for (const record of records) {
    if (record.type === "attributes") {
      if (isMermaidCode(record.target)) return true
      continue
    }
    for (const node of record.addedNodes) {
      if (node.nodeType !== 1) continue
      if (isMermaidCode(node) || node.querySelector(MERMAID_CODE_SELECTOR)) return true
    }
  }
  return false
}

// Swaps every not-yet-rendered mermaid <pre> under `root` for a
// <div class="mermaid"> holding the diagram source, and returns those divs
// for mermaid.run(). The <pre> is marked first, so a block is taken once.
export function takeMermaidBlocks(root) {
  const doc = root.ownerDocument || root
  const nodes = []
  root.querySelectorAll(MERMAID_CODE_SELECTOR).forEach((codeEl) => {
    const pre = codeEl.parentElement
    if (pre.dataset.mermaidRendered) return
    pre.dataset.mermaidRendered = "true"

    const container = doc.createElement("div")
    container.className = "mermaid"
    container.textContent = codeEl.textContent
    pre.replaceWith(container)
    nodes.push(container)
  })
  return nodes
}

// Starts watching `root`. `loadMermaid` resolves to the initialized mermaid
// module; it is called on the first block only and again only after a failed
// load. `nextFrame` batches a burst of patches into one pass.
export function startMermaidBlocks({
  root = document.body,
  loadMermaid,
  nextFrame = (cb) => requestAnimationFrame(cb),
  MutationObserverImpl = MutationObserver,
}) {
  let mermaidLoading = null
  let scheduled = false

  function schedule() {
    if (scheduled) return
    scheduled = true
    if (!mermaidLoading) mermaidLoading = Promise.resolve().then(loadMermaid)
    mermaidLoading.then(
      (mermaid) =>
        nextFrame(() => {
          scheduled = false
          const nodes = takeMermaidBlocks(root)
          if (nodes.length > 0) mermaid.run({ nodes })
        }),
      (err) => {
        scheduled = false
        mermaidLoading = null
        console.error("mermaid failed to load", err)
      }
    )
  }

  if (root.querySelector(MERMAID_CODE_SELECTOR)) schedule()

  const observer = new MutationObserverImpl((records) => {
    if (mutationsAddMermaid(records)) schedule()
  })
  observer.observe(root, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["class"],
  })
  return observer
}
