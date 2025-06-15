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
          cargo
        ];
      in
      {
        # https://github.com/hsjobeki/nixpkgs/blame/f0efec9cacfa9aef98a3c70fda2753b9825e262f/pkgs/top-level/all-packages.nix#L7018
        # https://github.com/hsjobeki/nixpkgs/blob/migrate-doc-comments/pkgs/build-support/build-bazel-package/default.nix#L8:C1
        #
        # This was built from just continually running `nix build` and checking for errors
        # and cross referencing the Envoy bazel docs.
        #
        # And seeing what failed, then adding it to this list and cross-referencing
        # https://github.com/NixOS/nixpkgs/blob/2365292db4959fe97a808b77beb8b9c0459944de/pkgs/by-name/en/envoy/package.nix
        #
        # I did all of this because the `wasmRuntime` override in nixpkgs.envoy
        # would not work and I wanted to apply patches for the WASM dependencies.
        packages.default = pkgs.buildBazelPackage rec {
          name = "envoy";
          version = "cmccurdy-build";
          bazel = pkgs.bazel_7;

          # source/exe/BUILD
          bazelTargets = [ "//source/exe:envoy-static" ];

          # We will apply patches to how bazel fetches dependencies so that builds
          # are hermetic. This is where Nix comes in to play!
          # patches = [];

          # buildBazelPackage is a wrapper of mkDerivation specifically for bazel packages
          # mkDerivation - https://github.com/NixOS/nixpkgs/blob/master/pkgs/stdenv/generic/make-derivation.nix
          # Phases - https://nixos.org/manual/nixpkgs/unstable/#sec-stdenv-phases
          # patchPhase
          # buildPhase
          # installPhase
          # checkPhase
          #
          # To be more specific, buildBazelPackage is actually two mkDerivation calls.
          # One for the fetchPhase (fetchAttrs) and one for buildPhase (buildAttrs).
          #
          # You shouldn't be doing too much mucking with derivation phases outside
          # of fetchAttrs and buildAttrs.

          # Bazel does it's own dependency fetching, but we use nix to make it
          # hermetic. We've applied patches above to use nix VM paths to make
          # builds hermetic.
          fetchAttrs = {
            hash = "sha256:${pkgs.lib.fakeSha256}";

            # The current `lockfile` is out of date for 'dynamic_modules_rust_sdk_crate_index'. Please re-run bazel using `CARGO_BAZEL_REPIN=true` if this is expected and the lockfile should be updated.
            env.CARGO_BAZEL_REPIN = true;
          };

          src = pkgs.applyPatches {
            src = ./.;

            # By convention, these patches are generated like:
            # git format-patch --zero-commit --signoff --no-numbered --minimal --full-index --no-signature
            patches = [
              # use system C/C++ tools
              ./nix/patches/0003-nixpkgs-use-system-C-C-toolchains.patch
            ];
          };

          postPatch = ''
            mkdir -p bazel/nix/
            substitute ${./nix/bazel_nix.BUILD.bazel} bazel/nix/BUILD.bazel \
              --subst-var-by bash "$(type -p bash)"

            # Replace these tools with the paths from Nix
            ln -sf "${pkgs.cargo}/bin/cargo" bazel/nix/cargo
            ln -sf "${pkgs.rustc}/bin/rustc" bazel/nix/rustc
            ln -sf "${pkgs.rustc}/bin/rustdoc" bazel/nix/rustdoc
            ln -sf "${pkgs.rustPlatform.rustLibSrc}" bazel/nix/ruststd

            substituteInPlace bazel/dependency_imports.bzl \
              --replace-fail 'crate_universe_dependencies()' 'crate_universe_dependencies(rust_toolchain_cargo_template="@@//bazel/nix:cargo", rust_toolchain_rustc_template="@@//bazel/nix:rustc")' \
              --replace-fail 'crates_repository(' 'crates_repository(rust_toolchain_cargo_template="@@//bazel/nix:cargo", rust_toolchain_rustc_template="@@//bazel/nix:rustc",'

            cp ${./nix/patches/rules_rust.patch} bazel/rules_rust.patch

            # uses nix bash instead of /usr/bin/env bash
            substitute ${./nix/patches/rules_rust_extra.patch} bazel/nix/rules_rust_extra.patch \
              --subst-var-by bash "$(type -p bash)"

            # combines replacing bash and replacing rustc/cargo version with "hermetic"
            cat bazel/nix/rules_rust_extra.patch bazel/rules_rust.patch > bazel/nix/rules_rust.patch
            # Replaces Envoy's bazel/rules_rust.patch with the Nix one
            mv bazel/nix/rules_rust.patch bazel/rules_rust.patch
          '';

          # CARGO_BAZEL_REPIN=true bazel build -c opt envoy
          # - https://github.com/envoyproxy/envoy/tree/main/bazel#production-environments
          bazelBuildFlags = [
            "-c opt envoy"
          ];

          buildAttrs = {
            # Things needed for buildPhase
            nativeBuildInputs = [
              pkgs.bazel
              pkgs.rustc
              pkgs.cargo
              pkgs.breakpointHook # debugging
            ];
            installPhase = ''
              install -Dm0755 bazel-bin/source/exe/envoy-static $out/bin/envoy
            '';
          };
        };

        formatter = pkgs.nixpkgs-fmt;
        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.nixpkgs-fmt
            pkgs.nil
            pkgs.deadnix
            pkgs.cargo
            pkgs.rustc
            pkgs.clang
            pkgs.libclang
            pkgs.stdenv.cc
          ];
          LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";
          BINDGEN_EXTRA_CLANG_ARGS = "--include-directory=${pkgs.stdenv.cc.libc.dev}/include";
        };
      }
    );
}
