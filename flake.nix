{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        packages.default = pkgs.envoy.overrideAttrs (_: {
          bazel = pkgs.bazel_6;
          src = pkgs.applyPatches
            {
              src = ./.;
              patches = [ ];
              postPatch = ''
                chmod -R +w .
                rm ./.bazelversion
              '';
            };

          wasmRuntime = "wasmtime";
        });

        formatter = pkgs.nixpkgs-fmt;
        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.nixpkgs-fmt
            pkgs.nil
            pkgs.deadnix
            pkgs.statix
            pkgs.cargo
            pkgs.rustc
            pkgs.clang
            pkgs.libclang
            pkgs.stdenv.cc
            pkgs.bazel_6
          ];
        };
      }
    );
}
