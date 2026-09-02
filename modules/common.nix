{
  config,
  lib,
  pkgs,
  ...
}:
{
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nixpkgs = {
    config.allowUnfree = true;
    flake = {
      setNixPath = true;
      setFlakeRegistry = true;
    };
  };

  services.openssh = {
    authorizedKeysFiles = lib.mkForce [ "/etc/ssh/authorized_keys.d/%u" ];
    enable = true;
    openFirewall = true;
    settings = {
      AllowAgentForwarding = false;
      AllowTcpForwarding = false;
      KbdInteractiveAuthentication = false;
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
      PubkeyAuthentication = true;
      X11Forwarding = false;
    };
  };
  services.fail2ban = {
    enable = true;
    maxretry = 5;
    bantime = "1h";
  };

  users.mutableUsers = false;
  users.users.root = {
    hashedPasswordFile = config.services.rezicsFleet.rootPasswordHashFile;
    openssh.authorizedKeys.keys = [ config.services.rezicsFleet.operatorAuthorizedKey ];
    openssh.authorizedKeys.keyFiles = [ ];
  };
  users.defaultUserShell = pkgs.fish;
  programs.fish.enable = true;

  programs.nix-ld.enable = true;
  environment.enableAllTerminfo = true;

  networking = {
    usePredictableInterfaceNames = false;
    # A and B declare their wired DHCP/static settings through
    # networking.interfaces.*.  Keep the scripted dhcpcd backend as the
    # single owner; enabling NetworkManager here would create competing
    # network units during boot.
    networkmanager.enable = false;
    firewall.enable = true;
  };

  boot.kernel.sysctl = {
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.default.accept_redirects" = 0;
  };

  services.journald.extraConfig = ''
    SystemMaxUse=2G
    MaxRetentionSec=30day
  '';

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
    randomizedDelaySec = "45min";
  };

  environment.systemPackages = with pkgs; [
    btop
    curl
    gh
    git
    htop
    jq
    micro
    nixfmt
    vim
    wget
  ];
}
