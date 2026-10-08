{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  cacert,
}:
stdenvNoCC.mkDerivation {
  pname = "stalwart-cli";
  version = "1.0.13";
  src = fetchurl {
    url = "https://github.com/stalwartlabs/cli/releases/download/v1.0.13/stalwart-cli-x86_64-unknown-linux-musl.tar.xz";
    sha256 = "689644a491c298b4916714a93a2a249ee2ea70f2f2c054991658c3e8f0f27c13";
  };
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    install -Dm755 stalwart-cli "$out/bin/stalwart-cli"
    wrapProgram "$out/bin/stalwart-cli" --set SSL_CERT_FILE "${cacert}/etc/ssl/certs/ca-bundle.crt"
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    "$out/bin/stalwart-cli" --version | grep -F '1.0.13'
  '';
  meta = {
    description = "Pinned upstream Stalwart JMAP management CLI";
    homepage = "https://stalw.art";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "stalwart-cli";
  };
}
