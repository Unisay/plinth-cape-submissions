{
  description = "Plinth source for UPLC-CAPE benchmark submissions";

  inputs = {
    haskell-nix = {
      url = "github:input-output-hk/haskell.nix";
      inputs.hackage.follows = "hackage";
    };

    nixpkgs.follows = "haskell-nix/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";

    hackage = {
      url = "github:input-output-hk/hackage.nix";
      flake = false;
    };

    CHaP = {
      url = "github:IntersectMBO/cardano-haskell-packages?ref=repo";
      flake = false;
    };

    iohk-nix = {
      url = "github:input-output-hk/iohk-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      haskell-nix,
      hackage,
      CHaP,
      iohk-nix,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = haskell-nix.config;
          overlays = [
            iohk-nix.overlays.crypto
            iohk-nix.overlays.cardano-lib
            haskell-nix.overlay
            iohk-nix.overlays.haskell-nix-crypto
            iohk-nix.overlays.haskell-nix-extra
          ];
        };

        project = pkgs.haskell-nix.cabalProject' {
          src = ./.;
          compiler-nix-name = "ghc967";
          inputMap = {
            "https://chap.intersectmbo.org/" = CHaP;
          };
          modules = [
            {
              packages.plinth-cape-submissions.package.buildable = true;
            }
          ];
        };

        plinthSubmissionsExe = project.hsPkgs.plinth-cape-submissions.components.exes.plinth-submissions;
      in
      {
        packages = {
          plinth-submissions = plinthSubmissionsExe;
          default = plinthSubmissionsExe;
        };

        devShells.default = project.shellFor {
          packages = p: [ p.plinth-cape-submissions ];
          tools = {
            cabal = "latest";
          };
          buildInputs = with pkgs; [
            fourmolu
            git
            pkg-config
            libsodium
            secp256k1
            libblst
          ];
          shellHook = ''
            echo "📦 Synchronizing Cabal package index..."
            cabal update > /dev/null 2>&1 || true
          '';
        };
      }
    );

  nixConfig = {
    extra-substituters = [
      "https://cache.iog.io"
      "https://cache.zw3rk.com"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
      "loony-tools:pr9m4BkM/5/eSTZlkQyRt57Jz7OMBxNSUiMC4FkcNfk="
    ];
    allow-import-from-derivation = true;
    accept-flake-config = true;
  };
}
