# `programs.tinycast.enable = true;`, with this flake's overlay applied or on its own.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.tinycast;
  # Relative to the user's home, resolved at activation: a literal `~` fails nix-darwin's shellcheck.
  keychain =
    if cfg.signing.keychain == null then "" else lib.removePrefix "~/" cfg.signing.keychain;
in
{
  options.programs.tinycast = {
    enable = lib.mkEnableOption "Tinycast, the macOS launcher";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.tinycast or (pkgs.callPackage ./package.nix { });
      defaultText = lib.literalExpression "pkgs.tinycast";
      description = "The Tinycast build to install.";
    };

    signing = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            identity = lib.mkOption {
              type = lib.types.str;
              default = "Tinycast Self-Signed";
              description = "Code-signing identity to re-sign the installed app with.";
            };
            keychain = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = "~/Library/Keychains/tinycast-signing.keychain-db";
              description = ''
                Keychain holding the identity. `~/`, or any relative path, starts at
                `system.primaryUser`'s home. A dedicated one that locks itself keeps other processes
                from signing an impostor between updates, and it is unlocked on install. Null
                searches the user's keychains.
              '';
            };
          };
        }
      );
      default = null;
      description = ''
        Unset, the ad-hoc build is installed in /Applications/Nix Apps, and macOS asks for its
        permissions again after every update, since an ad-hoc signature changes with each build.
        Set, the app is copied to /Applications/Tinycast.app and re-signed as
        `system.primaryUser` with this identity, so permissions and Keychain access carry over.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = lib.mkIf (cfg.signing == null) [ cfg.package ];

    system.activationScripts.postActivation.text =
      if cfg.signing != null then
        ''
          echo "installing Tinycast..." >&2
          ${pkgs.bash}/bin/bash ${./install-signed.sh} \
            ${lib.escapeShellArg "${cfg.package}/Applications/Tinycast.app"} \
            ${lib.escapeShellArg config.system.primaryUser} \
            ${lib.escapeShellArg cfg.signing.identity} \
            ${lib.escapeShellArg keychain} \
            || echo "warning: Tinycast was not installed or updated; see docs/signing.md in its repo" >&2
        ''
      else
        # A copy an earlier signed install left would sit beside the one in /Applications/Nix Apps.
        ''
          if [ -f /var/db/tinycast-nix/.tinycast-installed-from ]; then
            rm -rf /Applications/Tinycast.app /var/db/tinycast-nix
          fi
        '';
  };
}
