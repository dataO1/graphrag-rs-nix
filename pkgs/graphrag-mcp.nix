{ lib
, craneLib
, pkg-config
, openssl
}:

let
  src = craneLib.cleanCargoSource ../crates/graphrag-mcp;

  commonArgs = {
    inherit src;
    pname = "graphrag-mcp";
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
    description = "Stdio MCP server proxying tools to a graphrag-rs REST instance";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "graphrag-mcp";
  };
})
