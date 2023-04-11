{
  description = "Build a cargo project with a custom toolchain";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, crane, flake-utils, advisory-db, rust-overlay, ... }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ (import rust-overlay) ];
          };

          rustTarget = pkgs.rust-bin.selectLatestNightlyWith (toolchain: toolchain.default.override {
            extensions = [ "rust-src" "rust-analyzer" ];
            targets = [ "wasm32-unknown-unknown" ];
          });

          # NB: we don't need to overlay our custom toolchain for the *entire*
          # pkgs (which would require rebuidling anything else which uses rust).
          # Instead, we just want to update the scope that crane will use by appendings
          inherit (pkgs) lib;
          # our specific toolchain there.
          craneLib = (crane.mkLib pkgs).overrideToolchain rustTarget;
          #craneLib = crane.lib.${system};
          # Only keeps markdown files
          protoFilter = path: _type: builtins.match ".*proto$" path != null;
          sqlxFilter = path: _type: builtins.match ".*json$" path != null;
          protoOrCargo = path: type:
            (protoFilter path type) || (craneLib.filterCargoSources path type) || (sqlxFilter path type);
          # other attributes omitted
          src = lib.cleanSourceWith {
            src = ./.; # The original, unfiltered source
            filter = protoOrCargo;
          };
          #    src = craneLib.cleanCargoSource ./.;

          buildInputs = [
            # Add additional build inputs here
            pkgs.pkg-config
            pkgs.openssl
            pkgs.protobuf
          ] ++ lib.optionals pkgs.stdenv.isDarwin [
            # Additional darwin specific inputs can be set here
            pkgs.libiconv
          ];


          # Build *just* the cargo dependencies, so we can reuse
          # all of that work (e.g. via cachix) when running in CI
          cargoArtifacts = craneLib.buildDepsOnly {
            inherit src buildInputs;
          };

          # Build the actual crate itself, reusing the dependency
          # artifacts from above.
          vidette = craneLib.buildPackage {
            inherit cargoArtifacts src buildInputs;
            pname = "vidette";
            # Prevent cargo test and nextest from duplicating tests
            doCheck = false;
            # ALL CAPITAL derivations will get forwarded to mkDerivation and will set the env var during build
            SQLX_OFFLINE = "true";
            APP_ENVIRONMENT = "production";
          };

          # Deploy the image to Fly with our own bash script
          flyDeploy = pkgs.writeShellScriptBin "flyDeploy" ''
            OUT_PATH=$(nix build --print-out-paths .#container)
            HASH=$(echo $OUT_PATH | grep -Po "(?<=store\/)(.*?)(?=-)")
            ${pkgs.skopeo}/bin/skopeo --insecure-policy --debug copy docker-archive:"$OUT_PATH" docker://registry.fly.io/$FLY_PROJECT_NAME:$HASH --dest-creds x:"$FLY_AUTH_TOKEN" --format v2s2
            ${pkgs.flyctl}/bin/flyctl deploy -i registry.fly.io/$FLY_PROJECT_NAME:$HASH --remote-only
          '';
        in
        {
          checks = {
            # Build the crate as part of `nix flake check` for convenience
            inherit vidette;

            # Run clippy (and deny all warnings) on the crate source,
            # again, resuing the dependency artifacts from above.
            #
            # Note that this is done as a separate derivation so that
            # we can block the CI if there are issues here, but not
            # prevent downstream consumers from building our crate by itself.
            vidette-clippy = craneLib.cargoClippy {
              inherit cargoArtifacts src buildInputs;
              cargoClippyExtraArgs = "--all-targets -- --deny warnings";
            };

            vidette-doc = craneLib.cargoDoc {
              inherit cargoArtifacts src buildInputs;
            };

            # Check formatting
            vidette-fmt = craneLib.cargoFmt {
              inherit src;
            };

            # Audit dependencies
            vidette-audit = craneLib.cargoAudit {
              inherit src advisory-db;
            };

            # Run tests with cargo-nextest
            # Consider setting `doCheck = false` on `vidette` if you do not want
            # the tests to run twice
            # vidette-nextest = craneLib.cargoNextest {
            #  inherit cargoArtifacts src buildInputs;
            #  partitions = 1;
            #  partitionType = "count";
            #};
          } // lib.optionalAttrs (system == "x86_64-linux") {
            # NB: cargo-tarpaulin only supports x86_64 systems
            # Check code coverage (note: this will not upload coverage anywhere)
            #vidette-coverage = craneLib.cargoTarpaulin {
            #  inherit cargoArtifacts src;
            #};

          };

          packages.default = vidette;

          apps.default = flake-utils.lib.mkApp {
            drv = vidette;
          };

          # Create an option to build a docker image from this package 
          packages.container = pkgs.dockerTools.buildImage {
            name = "vidette";
            #tag = "latest";
            created = "now";
            copyToRoot = pkgs.buildEnv {
              name = "image-root";
              paths = [ pkgs.cacert ./.  ];
              pathsToLink = [ "/bin" "/configuration" "/keys" "/migrations" ];
            };
            config = {
              Env = [ "PATH=${vidette}/bin" "APP_ENVIRONMENT=production" ];

              ExposedPorts = {
                "8080/tcp" = { };
              };

              Cmd = [ "${vidette}/bin/vidette" ];
            };

          };

          apps.flyDeploy = flake-utils.lib.mkApp {
            drv = flyDeploy;
          };
          devShells.default = pkgs.mkShell {
            inputsFrom = builtins.attrValues self.checks;

            # Extra inputs can be added here
            nativeBuildInputs = with pkgs; [
              rustTarget
              openssl
              mysql80
              dive
              sqlx-cli
              pkg-config
              protobuf
              skopeo
              flyctl
            ];
            RUST_SRC_PATH = "${rustTarget}/lib/rustlib/src/rust/library";
          };
        });
}
