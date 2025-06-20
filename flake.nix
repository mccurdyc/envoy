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
        packages.default = pkgs.buildBazelPackage rec {
          name = "envoy";
          version = "cmccurdy-build";
          bazel = pkgs.bazel_6;

          # enableNixHacks option (enabled by default) that attempts to patch Bazel to use local resources and avoid network fetches.
          enableNixHacks = true;

          nativeBuildInputs = with pkgs; [
            cmake
            python3
            gn
            go
            jdk
            ninja
            patchelf
            cacert

            bazel_6

            # debugging
            breakpointHook
            neovim
          ];

          # https://discourse.nixos.org/t/bazel-enablenixhacks/15203
          buildInputs = [ pkgs.linuxHeaders ];

          src = pkgs.applyPatches {
            src = ./.;

            # By convention, these patches are generated like:
            # git commit
            # git format-patch -1 HEAD --zero-commit --signoff --no-numbered --minimal --full-index --no-signature
            # git reset --hard HEAD~1
            patches = [
              # use system Python
              ./nix/patches/0001-python.patch

              # use system C/C++ tools
              ./nix/patches/0003-nixpkgs-use-system-C-C-toolchains.patch

              # bump rules_rust to support newer Rust
              ./nix/patches/0004-nixpkgs-bump-rules_rust-to-0.60.0.patch
            ];

            # Removes the Envoy .bazelversion which says to use 7.6.0.
            postPatch = ''
              chmod -R +w .
              rm ./.bazelversion
            '';
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

            # patch rules_rust for envoy specifics, but also to support old Bazel
            # (Bazel 6 doesn't have ctx.watch, but ctx.path is sufficient for our use)
            cp ${./nix/patches/rules_rust.patch} bazel/rules_rust.patch
            substituteInPlace bazel/repositories.bzl \
              --replace-fail ', "@envoy//bazel:rules_rust_ppc64le.patch"' ""

            # uses nix bash instead of /usr/bin/env bash
            substitute ${./nix/patches/rules_rust_extra.patch} bazel/nix/rules_rust_extra.patch \
              --subst-var-by bash "$(type -p bash)"

            # combines replacing bash and replacing rustc/cargo version with "hermetic"
            cat bazel/nix/rules_rust_extra.patch bazel/rules_rust.patch > bazel/nix/rules_rust.patch
            # Replaces Envoy's bazel/rules_rust.patch with the Nix one
            mv bazel/nix/rules_rust.patch bazel/rules_rust.patch
          '';

          fetchAttrs = {
            hash = pkgs.lib.fakeHash;

            # The current `lockfile` is out of date for 'dynamic_modules_rust_sdk_crate_index'.
            #  Please re-run bazel using `CARGO_BAZEL_REPIN=true` if this is expected and the lockfile should be updated.
            env.CARGO_BAZEL_REPIN = true;
            dontUseCmakeConfigure = true;
            dontUseGnConfigure = true;

            postPatch = ''
              ${postPatch}

              substituteInPlace bazel/dependency_imports.bzl \
                --replace-fail 'crate_universe_dependencies(' 'crate_universe_dependencies(bootstrap=True, ' \
                --replace-fail 'crates_repository(' 'crates_repository(generator="@@cargo_bazel_bootstrap//:cargo-bazel", '
            '';

            preInstall = ''
              sed -i \
                -e 's,${pkgs.stdenv.shellPackage},__NIXSHELL__,' \
                -e 's,${builtins.storeDir}/[^/]\+/bin/bash,__NIXBASH__,' \
                $bazelOut/external/local_config_sh/BUILD \
                $bazelOut/external/rules_rust/util/process_wrapper/private/process_wrapper.sh \
                $bazelOut/external/rules_rust/crate_universe/src/metadata/cargo_tree_rustc_wrapper.sh

              # Install repinned rules_rust lockfile
              cp source/extensions/dynamic_modules/sdk/rust/Cargo.Bazel.lock $bazelOut/external/Cargo.Bazel.lock

              # Don't save cargo_bazel_bootstrap or the crate index cache
              rm -rf $bazelOut/external/cargo_bazel_bootstrap $bazelOut/external/dynamic_modules_rust_sdk_crate_index/.cargo_home $bazelOut/external/dynamic_modules_rust_sdk_crate_index/splicing-output
            '';
          };

          # CARGO_BAZEL_REPIN=true bazel build -c opt envoy
          # - https://github.com/envoyproxy/envoy/tree/main/bazel#production-environments
          removeRulesCC = false;
          removeLocalConfigCc = true;
          removeLocal = false;

          # source/exe/BUILD
          bazelTargets = [ "//source/exe:envoy-static" ];

          bazelFetchFlags = [
            # Force use of system Rust defined in our rules_rust patch
            "--extra_toolchains=//bazel/nix:rust_nix_aarch64,//bazel/nix:rust_nix_x86_64"
          ];

          bazelBuildFlags = [
            "-c opt"
            "--verbose_failures"

            # Force use of system Rust defined in our rules_rust patch
            "--extra_toolchains=//bazel/nix:rust_nix_aarch64,//bazel/nix:rust_nix_x86_64"
          ];


          buildAttrs = {
            dontUseCmakeConfigure = true;
            dontUseGnConfigure = true;
            dontUseNinjaInstall = true;

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
            pkgs.statix
            pkgs.cargo
            pkgs.rustc
            pkgs.clang
            pkgs.libclang
            pkgs.stdenv.cc
            pkgs.bazel_6
          ];
          LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";
          BINDGEN_EXTRA_CLANG_ARGS = "--include-directory=${pkgs.stdenv.cc.libc.dev}/include";
        };
      }
    );
}
