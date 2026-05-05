{ lib
, craneLib
, pkg-config
, openssl
}:

let
  src = craneLib.cleanCargoSource ../crates/knowledge-watcher;

  commonArgs = {
    inherit src;
    pname = "knowledge-watcher";
    version = "0.1.0";
    strictDeps = true;

    nativeBuildInputs = [ pkg-config ];
    buildInputs = [ openssl ];

    OPENSSL_NO_VENDOR = "1";
  };

  cargoArtifacts = craneLib.buildDepsOnly commonArgs;
in
craneLib.buildPackage (commonArgs // {
  inherit cargoArtifacts;

  meta = {
    description = "Filesystem watcher that keeps the local knowledge graph in sync (initial walk + live inotify, gitignore-aware, text-only)";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "knowledge-watcher";
  };
})
