{ config, pkgs, ... }:
let
  nomadAutoscaler = pkgs.stdenvNoCC.mkDerivation {
    pname = "nomad-autoscaler";
    version = "0.4.9";

    src = pkgs.fetchurl {
      url = "https://releases.hashicorp.com/nomad-autoscaler/0.4.9/nomad-autoscaler_0.4.9_linux_amd64.zip";
      hash = "sha256-S4nE0mZmPJeVsykwGZxImmdgasE/A+f8qNoVoFE6bKc=";
    };

    dontUnpack = true;
    nativeBuildInputs = [ pkgs.unzip ];
    installPhase = ''
      runHook preInstall
      install -d "$out/bin"
      unzip "$src" nomad-autoscaler -d "$TMPDIR"
      install -m 0755 "$TMPDIR/nomad-autoscaler" "$out/bin/nomad-autoscaler"
      runHook postInstall
    '';

    meta = {
      description = "Nomad horizontal application autoscaler";
      homepage = "https://developer.hashicorp.com/nomad/tools/autoscaling";
      license = pkgs.lib.licenses.mpl20;
      mainProgram = "nomad-autoscaler";
      platforms = [ "x86_64-linux" ];
    };
  };
  reconcileNomadAutoscaler = pkgs.writeShellApplication {
    name = "reconcile-nomad-autoscaler";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      config.services.nomad.package
    ];
    text = builtins.readFile ../scripts/reconcile-nomad-autoscaler.sh;
  };
  reconcileStart = pkgs.writeShellScript "start-reconcile-nomad-autoscaler" ''
    export NOMAD_ADDR=https://127.0.0.1:4646
    export NOMAD_CACERT="$CREDENTIALS_DIRECTORY/nomad-ca"
    export NOMAD_CLIENT_CERT="$CREDENTIALS_DIRECTORY/nomad-client-cert"
    export NOMAD_CLIENT_KEY="$CREDENTIALS_DIRECTORY/nomad-client-key"
    export NOMAD_TLS_SERVER_NAME=server.global.nomad
    export REZICS_NOMAD_MANAGEMENT_TOKEN_FILE="$CREDENTIALS_DIRECTORY/management-token"
    export REZICS_NOMAD_AUTOSCALER_TOKEN_FILE=/var/lib/nomad-autoscaler/nomad.token
    exec ${reconcileNomadAutoscaler}/bin/reconcile-nomad-autoscaler
  '';
  autoscalerStart = pkgs.writeShellScript "start-nomad-autoscaler" ''
    export NOMAD_ADDR=https://127.0.0.1:4646
    export NOMAD_CACERT="$CREDENTIALS_DIRECTORY/nomad-ca"
    export NOMAD_CLIENT_CERT="$CREDENTIALS_DIRECTORY/nomad-client-cert"
    export NOMAD_CLIENT_KEY="$CREDENTIALS_DIRECTORY/nomad-client-key"
    export NOMAD_TLS_SERVER_NAME=server.global.nomad
    NOMAD_TOKEN="$(<"$CREDENTIALS_DIRECTORY/nomad-token")"
    export NOMAD_TOKEN
    exec ${nomadAutoscaler}/bin/nomad-autoscaler agent \
      -log-json \
      -http-bind-address=127.0.0.1 \
      -http-bind-port=15001 \
      -nomad-address=https://127.0.0.1:4646 \
      -nomad-region=global \
      -nomad-namespace=rezics \
      -nomad-block-query-wait-time=1m \
      -policy-source-disable-file \
      -telemetry-disable-hostname \
      -telemetry-prometheus-metrics
  '';
  nomadTlsCredentials = [
    "nomad-ca:/var/lib/rezics-deploy/nomad-tls/nomad-agent-ca.pem"
    "nomad-client-cert:/var/lib/rezics-deploy/nomad-tls/global-cli-nomad.pem"
    "nomad-client-key:/var/lib/rezics-deploy/nomad-tls/global-cli-nomad-key.pem"
  ];
in
{
  environment.systemPackages = [ nomadAutoscaler ];

  systemd.tmpfiles.rules = [
    "d /var/lib/nomad-autoscaler 0700 root root - -"
  ];

  systemd.services.rezics-nomad-autoscaler-credentials = {
    description = "Reconcile the scoped Nomad Autoscaler ACL credential";
    after = [ "nomad.service" ];
    requires = [ "nomad.service" ];
    unitConfig.ConditionPathExists = [
      "/root/.config/nomad/management.token"
      "/var/lib/rezics-deploy/nomad-tls/nomad-agent-ca.pem"
      "/var/lib/rezics-deploy/nomad-tls/global-cli-nomad.pem"
      "/var/lib/rezics-deploy/nomad-tls/global-cli-nomad-key.pem"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = reconcileStart;
      LoadCredential = [
        "management-token:/root/.config/nomad/management.token"
      ]
      ++ nomadTlsCredentials;
      UMask = "0077";
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectProc = "invisible";
      ProtectSystem = "strict";
      ReadWritePaths = [ "/var/lib/nomad-autoscaler" ];
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
    };
  };

  systemd.services.rezics-nomad-autoscaler = {
    description = "Scale REZICS Nomad workloads within declared policy bounds";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "rezics-nomad-autoscaler-credentials.service"
    ];
    wants = [ "network-online.target" ];
    requires = [ "rezics-nomad-autoscaler-credentials.service" ];
    unitConfig.ConditionPathExists = [
      "/var/lib/nomad-autoscaler/nomad.token"
      "/var/lib/rezics-deploy/nomad-tls/nomad-agent-ca.pem"
      "/var/lib/rezics-deploy/nomad-tls/global-cli-nomad.pem"
      "/var/lib/rezics-deploy/nomad-tls/global-cli-nomad-key.pem"
    ];
    serviceConfig = {
      Type = "simple";
      DynamicUser = true;
      ExecStart = autoscalerStart;
      LoadCredential = [
        "nomad-token:/var/lib/nomad-autoscaler/nomad.token"
      ]
      ++ nomadTlsCredentials;
      Restart = "on-failure";
      RestartSec = "3s";
      UMask = "0077";
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectProc = "invisible";
      ProtectSystem = "strict";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
    };
  };
}
