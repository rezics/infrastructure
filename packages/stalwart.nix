{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  cacert,
}:
stdenvNoCC.mkDerivation {
  pname = "stalwart";
  version = "0.16.25";
  src = fetchurl {
    url = "https://github.com/stalwartlabs/stalwart/releases/download/v0.16.25/stalwart-x86_64-unknown-linux-musl.tar.gz";
    sha256 = "cbe04e89adae7bb2b6a55b7cce3f1b33ab66700a0fa3174446efb3b53810b92e";
  };
  sourceRoot = ".";
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    install -Dm755 stalwart "$out/bin/stalwart"
    wrapProgram "$out/bin/stalwart" --set SSL_CERT_FILE "${cacert}/etc/ssl/certs/ca-bundle.crt"
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    "$out/bin/stalwart" --version | grep -Fx '0.16.25'
  '';
  meta = {
    description = "Pinned upstream Stalwart static release";
    homepage = "https://stalw.art";
    license = lib.licenses.agpl3Only;
    platforms = [ "x86_64-linux" ];
    mainProgram = "stalwart";
  };
}
