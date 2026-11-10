{
  description = "Tinycast (domwst fork), built from source with the host's Xcode";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forEachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      overlays.default = final: _prev: { tinycast = final.callPackage ./nix/package.nix { }; };

      darwinModules.default = ./nix/darwin-module.nix;

      packages = forEachSystem (pkgs: rec {
        tinycast = pkgs.callPackage ./nix/package.nix { };
        default = tinycast;
      });
    };
}
