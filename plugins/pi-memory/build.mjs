// esbuild one-liner — bundles src/index.ts → dist/index.js.
// Externalizes all pi runtime deps (resolved by pi's jiti at load time).
// Run: node build.mjs

import * as esbuild from "esbuild";

const external = [
  "@mariozechner/pi-coding-agent",
  "@mariozechner/pi-tui",
  "@mariozechner/pi-ai",
  "typebox",
  "fs",
  "path",
  "os",
  "crypto",
];

await esbuild.build({
  entryPoints: ["src/index.ts"],
  bundle: true,
  outfile: "dist/index.js",
  format: "esm",
  platform: "node",
  target: "node20",
  external,
  sourcemap: true,
  minify: false,
});

console.log("✓ pi-memory built → dist/index.js");
