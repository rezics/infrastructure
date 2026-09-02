{ buildGoModule, lib }:

buildGoModule {
  pname = "rezics-release-gateway";
  version = "1.0.0";
  src = ../services/release-gateway;
  vendorHash = null;

  env.CGO_ENABLED = "0";
  ldflags = [
    "-s"
    "-w"
  ];

  meta = {
    description = "OIDC-authenticated gateway for dispatching fixed REZICS release jobs";
    license = lib.licenses.agpl3Only;
    mainProgram = "release-gateway";
    platforms = [ "x86_64-linux" ];
  };
}
