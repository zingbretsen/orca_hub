// Loads the page-specific bundles that are kept out of app.js (the
// `orca_hub_lazy` esbuild profile in config/config.exs): xterm for the
// Terminal hook, mermaid for ```mermaid blocks.
//
// root.html.heex publishes each bundle's URL in a
// `<meta name="orca-lazy:<name>" content="...">` tag, so app.js hard-codes no
// path and prod gets phx.digest's digested, immutably cached one. Those meta
// tags sit in <head>, outside every LiveView, so they survive live navigation.

export const LAZY_META_PREFIX = "orca-lazy:"

export function lazyAssetUrl(name, doc = document) {
  const meta = doc.querySelector(`meta[name="${LAZY_META_PREFIX}${name}"]`)
  const url = meta && meta.getAttribute("content")
  if (!url) throw new Error(`no <meta name="${LAZY_META_PREFIX}${name}"> in the root layout`)
  return url
}

// One promise per URL for the life of the page, so two Terminal hooks that
// mount together share one fetch. A failed load is forgotten, so the next
// caller tries again instead of inheriting the failure.
//
// `importModule` is injectable for the node checks. In the browser it is a
// native import() of a runtime URL, which esbuild leaves alone in the IIFE
// app.js because the argument is not a string literal.
export function createLazyLoader({ doc = document, importModule = (url) => import(url) } = {}) {
  const modules = new Map()
  const stylesheets = new Map()

  function loadModule(name) {
    let url
    try {
      url = lazyAssetUrl(name, doc)
    } catch (err) {
      return Promise.reject(err)
    }
    if (!modules.has(url)) {
      const loading = Promise.resolve().then(() => importModule(url))
      loading.catch(() => modules.delete(url))
      modules.set(url, loading)
    }
    return modules.get(url)
  }

  // Resolves true once the stylesheet has loaded, false if it failed. It never
  // rejects: a terminal without its CSS still works, it only looks wrong, so
  // the caller opens it either way.
  function loadStylesheet(name) {
    let url
    try {
      url = lazyAssetUrl(name, doc)
    } catch (err) {
      console.error(err)
      return Promise.resolve(false)
    }
    if (!stylesheets.has(url)) {
      const loading = new Promise((resolve) => {
        const link = doc.createElement("link")
        link.rel = "stylesheet"
        link.href = url
        link.addEventListener("load", () => resolve(true))
        link.addEventListener("error", () => {
          stylesheets.delete(url)
          link.remove()
          console.error(`failed to load stylesheet ${url}`)
          resolve(false)
        })
        doc.head.appendChild(link)
      })
      stylesheets.set(url, loading)
    }
    return stylesheets.get(url)
  }

  return { loadModule, loadStylesheet }
}

let sharedLoader = null

// The page's one loader. Created on first use, not at import time, so this
// module also loads under node (the check scripts) where there is no document.
export function lazyLoader() {
  if (!sharedLoader) sharedLoader = createLazyLoader()
  return sharedLoader
}
