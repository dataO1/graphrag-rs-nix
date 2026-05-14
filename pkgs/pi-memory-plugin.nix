# pi-memory-plugin — esbuild-bundled pi extension for long-term memory.
#
# Takes the TypeScript source from ../plugins/pi-memory, bundles it
# via esbuild into a single dist/index.js ESM file, and exposes the
# dist/ tree. The home-manager module (modules/home-manager.nix or
# the dotfiles pi.nix) links dist/index.js into ~/.pi/agent/extensions/.
#
# Dependencies (@mariozechner/pi-*, typebox) are externalised — they
# resolve from pi's own node_modules at load time (pi uses jiti, so
# both .js and .ts extensions load fine).
{
  lib,
  stdenv,
  esbuild,
  nodejs,
}:

let
  src = ../plugins/pi-memory;
in
stdenv.mkDerivation {
  name = "pi-memory-plugin";
  inherit src;

  nativeBuildInputs = [ esbuild nodejs ];

  buildPhase = ''
    esbuild src/index.ts \
      --bundle \
      --outfile=dist/index.js \
      --format=esm \
      --platform=node \
      --target=node20 \
      --external:@mariozechner/pi-coding-agent \
      --external:@mariozechner/pi-tui \
      --external:@mariozechner/pi-ai \
      --external:typebox \
      --external:fs \
      --external:path \
      --external:os \
      --external:crypto \
      --sourcemap \
      --log-level=warning
  '';

  installPhase = ''
    mkdir -p $out
    cp -r dist $out/
  '';

  meta = with lib; {
    description =
      "Long-term memory extension for pi coding agent (recall, remember, forget, catalog, status, log)";
    license = licenses.mit;
    platforms = platforms.all;
  };
}
