{
  description = "Sessions that haunt your terminal. A GNU screen style terminal multiplexer built on libghostty.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib;
        zig = pkgs.zig_0_15;

        # Single source of truth for the version is build.zig.zon.
        version = builtins.head (
          builtins.match ''.*\.version = "([^"]+)".*'' (builtins.readFile ./build.zig.zon)
        );

        # Zig package cache containing every dependency pinned in
        # build.zig.zon (libghostty and its transitive dependencies).
        # Pre-fetched as a fixed-output derivation so the sandboxed
        # build below needs no network access. When dependencies in
        # build.zig.zon change, update outputHash (set it to
        # lib.fakeHash, build, and copy the hash from the error).
        deps = pkgs.stdenvNoCC.mkDerivation {
          pname = "boo-deps";
          inherit version;
          src = ./.;

          nativeBuildInputs = [ zig ];

          dontConfigure = true;
          dontBuild = true;
          dontFixup = true;

          installPhase = ''
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
            zig build --fetch=all
            mv "$ZIG_GLOBAL_CACHE_DIR/p" "$out"
          '';

          impureEnvVars = lib.fetchers.proxyImpureEnvVars;
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = "sha256-2dZHdZoAap25va9ka2SN5QqoQ2xcZITJKNzwfOGmvus=";
        };

        boo = pkgs.stdenv.mkDerivation {
          pname = "boo";
          inherit version;
          src = ./.;

          nativeBuildInputs = [ zig.hook ];

          # zig.hook builds with --release=safe, matching the
          # optimization mode of the published release binaries.
          #
          # The dependency cache is copied, not symlinked: some
          # ghostty build steps run helper executables with a working
          # directory inside the package cache and locate their
          # outputs via relative paths, which resolve incorrectly
          # through a symlink into the store.
          postConfigure = ''
            cp -r --no-preserve=mode ${deps} "$ZIG_GLOBAL_CACHE_DIR/p"
          '';

          # Runs `zig build test` (unit tests; no TTY required). The
          # PTY integration tests stay in CI via `zig build test-all`.
          doCheck = true;

          meta = {
            description = "Sessions that haunt your terminal. A GNU screen style terminal multiplexer built on libghostty";
            homepage = "https://github.com/coder/boo";
            license = lib.licenses.mit;
            mainProgram = "boo";
            platforms = lib.platforms.linux ++ lib.platforms.darwin;
          };
        };
      in
      {
        packages = {
          default = boo;
          inherit boo;
        };

        devShells.default = pkgs.mkShell {
          packages = [ zig ];
        };

        formatter = pkgs.nixfmt-tree;
      }
    );
}
