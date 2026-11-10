# `programs.tinycast.enable = true;`, with this flake's overlay applied or on its own.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.tinycast;
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
              example = "Tinycast Self-Signed";
              description = "Code-signing identity to re-sign the installed app with.";
            };
            keychain = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "/Users/me/Library/Keychains/tinycast-signing.keychain-db";
              description = ''
                Keychain holding the identity. A dedicated one that locks itself keeps other
                processes from signing an impostor between updates; it is unlocked on install.
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

    system.activationScripts.postActivation.text = lib.mkIf (cfg.signing != null) ''
      echo "installing Tinycast..." >&2
      ${pkgs.bash}/bin/bash ${./install-signed.sh} \
        ${lib.escapeShellArg "${cfg.package}/Applications/Tinycast.app"} \
        ${lib.escapeShellArg config.system.primaryUser} \
        ${lib.escapeShellArg cfg.signing.identity} \
        ${lib.escapeShellArg (if cfg.signing.keychain == null then "" else cfg.signing.keychain)} \
        || echo "warning: Tinycast was not updated; the previous copy stays in place" >&2
    '';
  };
}
