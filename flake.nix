{
  description = "Cardano Open Oracle Protocol";

  inputs = {
    # LambdaBuffers as source of truth for many inputs
    lbf.url = "github:mlabs-haskell/lambda-buffers";

    # Flake monorepo toolkit
    flake-lang.url = "github:mlabs-haskell/flake-lang.nix";

    # Nix
    nixpkgs.follows = "lbf/nixpkgs";
    flake-parts.follows = "lbf/flake-parts";

    ## Code quality automation
    pre-commit-hooks.follows = "lbf/pre-commit-hooks";
    hci-effects.follows = "lbf/hci-effects";

    # Plutarch (Plutus validation scripts)
    plutarch.follows = "lbf/plutarch";

    # Plutip for spawning local Cardano networks
    plutip.url = "github:mlabs-haskell/plutip";

    # Light-weight wrapper around cardano-node
    ogmios.url = "github:mlabs-haskell/ogmios-nixos";

  };
  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        ./pkgs.nix
        ./settings.nix
        ./pre-commit.nix
        ./hercules-ci.nix

        # Libraries
        ./tx-bakery/build.nix
        ./tx-bakery-plutip/build.nix
        ./tx-bakery-ogmios/build.nix
        ./extras/tx-bakery-testsuite/api/build.nix

        # Extras
        ./extras/tx-bakery-testsuite/validation/build.nix
        ./extras/tx-bakery-testsuite/tests/build.nix
      ];
      debug = true;
      systems = [ "x86_64-linux" "x86_64-darwin" ];
    };
}
