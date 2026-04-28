{ lib
, stdenv
, craneLib
, src
, pkg-config
, openssl
, protobuf
, cmake
, perl
}:

let
  commonArgs = {
    inherit src;
    pname = "graphrag-rs";
    version = "0.1.0";
    strictDeps = true;

    nativeBuildInputs = [ pkg-config protobuf cmake perl ];
    buildInputs = [ openssl ];

    # qdrant-client (gRPC via tonic) and reqwest both pull native deps.
    PROTOC = "${protobuf}/bin/protoc";
    OPENSSL_NO_VENDOR = "1";

    # Workspace contains wasm + python crates we don't want to build here.
    cargoExtraArgs = "--locked -p graphrag-server -p graphrag-cli";

    # The workspace exclude list already drops examples/web-app, but the
    # leptos/wasm-bindgen workspace deps still want to resolve their target
    # toolchains. Skipping doctest avoids tickling them.
    doCheck = false;
  };

  cargoArtifacts = craneLib.buildDepsOnly commonArgs;

  # Build server + cli together so deps are shared.
  workspace = craneLib.buildPackage (commonArgs // {
    inherit cargoArtifacts;
  });

  # Per-binary derivations exposed via .server and .cli for clarity.
  server = workspace.overrideAttrs (_: { pname = "graphrag-server"; meta.mainProgram = "graphrag-server"; });
  cli = workspace.overrideAttrs (_: { pname = "graphrag-cli"; meta.mainProgram = "graphrag-cli"; });
in
workspace // {
  inherit server cli;

  meta = {
    description = "High-performance Rust GraphRAG implementation (server + CLI)";
    homepage = "https://github.com/automataIA/graphrag-rs";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    maintainers = [ ];
  };
}
