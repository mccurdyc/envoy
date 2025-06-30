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
        # https://nixos.org/manual/nixpkgs/stable/#sec-pkg-overrideAttrs
        # Function arguments can be omitted entirely if there is no need to access previousAttrs or finalAttrs.
        # overrideAttrs should be preferred in (almost) all cases to overrideDerivation
        packages.default = pkgs.buildBazelPackage {
          src = pkgs.applyPatches
            {
              src = ./.;
              patches = [ ];
            };

          fetchAttrs = { };
          buildAttrs = { };

          nativeBuildInputs = [
            # Envoy expects 7.6.0
            pkgs.bazel_7
            # If you use version 7.6.0, you must also enable these "nix hacks" for version 7.
            (pkgs.bazel_7.override { enableNixHacks = true; })

            # debugging
            pkgs.breakpointHook
          ];

          # Envoy expects 7.6.0
          bazel = pkgs.bazel_7;
          buildAttrs = {
            nativeBuildInputs = [
              # Envoy expects 7.6.0
              pkgs.bazel_7
              # If you use version 7.6.0, you must also enable these "nix hacks" for version 7.
              (pkgs.bazel_7.override { enableNixHacks = true; })

              # debugging
              pkgs.breakpointHook
            ];
          };
          wasmRuntime = "wasmtime";
        };

        formatter = pkgs.nixpkgs-fmt;
        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.nixpkgs-fmt
            pkgs.nil
            pkgs.deadnix
            pkgs.statix
          ];
        };
      }
    );
}
