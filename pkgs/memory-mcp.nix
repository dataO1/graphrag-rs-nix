{ lib
, craneLib
, pkg-config
, openssl
}:

let
  src = craneLib.cleanCargoSource ../crates/memory-mcp;

  commonArgs = {
    inherit src;
    pname = "memory-mcp";
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
    description = "Stdio MCP server exposing the user's long-term memory (recall/remember/forget) over a graphrag-rs REST backend";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "memory-mcp";
  };
})
