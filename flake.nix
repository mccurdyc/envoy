{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            (final: prev: {
              # must match .bazelversion (7.6.0)
              bazel_7 = prev.bazel_7.override {
                version = "7.6.0";
              };
            })
          ];
        };

        packages = with pkgs; [
          nil
          deadnix
          statix
          nixpkgs-fmt

          # must match .bazelversion (7.6.0)
          bazel_7
        ];
      in
      {
        formatter = pkgs.nixpkgs-fmt;
        devShells.default = pkgs.mkShell {
          inherit packages;
        };
      }
    );
}
