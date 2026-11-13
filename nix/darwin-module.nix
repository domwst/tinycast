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
  user = lib.escapeShellArg config.system.primaryUser;
  # The release build's preferences domain; a Debug build keeps its own, so it is never touched.
  defaults = lib.concatStringsSep " " [
    "/bin/launchctl asuser \"$(/usr/bin/id -u ${user})\""
    "/usr/bin/sudo -H -u ${user} -- /usr/bin/defaults write com.tinycast.app"
  ];

  install =
    if cfg.signing != null then
      ''
        echo "installing Tinycast..." >&2
        ${pkgs.bash}/bin/bash ${./install-signed.sh} \
          ${lib.escapeShellArg "${cfg.package}/Applications/Tinycast.app"} \
          ${user} \
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

  # Preferences, not settings.json: neither key has one, so no synced file can arm or repoint it.
  python =
    ''
      ${defaults} pythonEnabled -bool true \
        || echo "warning: couldn't switch on Tinycast's Python prompt" >&2
    ''
    + lib.optionalString (cfg.python.package != null) ''
      ${defaults} pythonInterpreterPath -string ${
        lib.escapeShellArg "${cfg.python.package}/bin/python3"
      } || echo "warning: couldn't set Tinycast's Python interpreter" >&2
    '';
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

    python = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Switches on the Python prompt, which typing `py` in the launcher opens. Left false, the
          module leaves whatever was chosen in Settings alone. Tinycast reads it when it starts.
        '';
      };
      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        example = lib.literalExpression "pkgs.python3.withPackages (ps: [ ps.numpy ])";
        description = ''
          The interpreter whose `bin/python3` the prompt runs. Null keeps the path set in
          Settings, which when empty is the `python3` the login shell finds.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = lib.mkIf (cfg.signing == null) [ cfg.package ];

    system.activationScripts.postActivation.text = lib.mkMerge [
      install
      (lib.mkIf cfg.python.enable python)
    ];
  };
}
