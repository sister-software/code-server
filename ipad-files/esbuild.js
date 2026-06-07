// Bundles the extension into a single browser/worker-compatible file.
// The web extension host loads dist/extension.js inside a Web Worker, so we
// target the browser platform and leave `vscode` external (provided by the host).
const esbuild = require("esbuild")

const watch = process.argv.includes("--watch")

const options = {
  entryPoints: ["src/extension.ts"],
  bundle: true,
  format: "cjs",
  platform: "browser",
  target: "es2020",
  outfile: "dist/extension.js",
  external: ["vscode"],
  sourcemap: true,
  logLevel: "info",
}

async function main() {
  if (watch) {
    const ctx = await esbuild.context(options)
    await ctx.watch()
    console.log("watching…")
  } else {
    await esbuild.build(options)
  }
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
