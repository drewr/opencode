{
  description = "OpenCode development flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "aarch64-linux"
        "x86_64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      bunOverlay = final: prev: {
        bun =
          let
            system = final.stdenv.hostPlatform.system;
            zipName =
              if system == "x86_64-linux" then "bun-linux-x64.zip"
              else if system == "aarch64-linux" then "bun-linux-aarch64.zip"
              else if system == "aarch64-darwin" then "bun-darwin-aarch64.zip"
              else "bun-darwin-x64.zip";
            zipUrl = "https://github.com/oven-sh/bun/releases/download/bun-v1.3.14/${zipName}";
            zipHash = prev.lib.fakeHash;
          in
          prev.stdenvNoCC.mkDerivation {
            pname = "bun";
            version = "1.3.14";
            src = prev.fetchzip {
              url = zipUrl;
              hash = zipHash;
            };
            installPhase = ''
              mkdir -p $out/bin $out/lib
              cp bun $out/bin/bun
              chmod +x $out/bin/bun
              cp -r lib/* $out/lib/ 2>/dev/null || true
            '';
            meta = prev.bun.meta // { description = "Bun runtime 1.3.14"; };
          };
      };
      pkgsFor = system: import nixpkgs {
        inherit system;
        overlays = [ bunOverlay ];
      };
      forEachSystem = f: nixpkgs.lib.genAttrs systems (system: f (pkgsFor system));
      rev = self.shortRev or self.dirtyShortRev or "dirty";
    in
    {
      devShells = forEachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            bun
            nodejs_20
            pkg-config
            openssl
            git
          ];
        };
      });

      overlays = {
        default =
          final: _prev:
          let
            node_modules = final.callPackage ./nix/node_modules.nix {
              inherit rev;
            };
          in
          rec {
            opencode = final.callPackage ./nix/opencode.nix {
              inherit node_modules;
            };
            opencode-desktop = final.callPackage ./nix/desktop.nix {
              inherit opencode;
            };
          };
      };

      packages = forEachSystem (
        pkgs:
        let
          node_modules = pkgs.callPackage ./nix/node_modules.nix {
            inherit rev;
          };
        in
        rec {
          default = opencode;
          opencode = pkgs.callPackage ./nix/opencode.nix {
            inherit node_modules;
          };
          opencode-desktop = pkgs.callPackage ./nix/desktop.nix {
            inherit opencode;
          };
          # Updater derivation with fakeHash - build fails and reveals correct hash
          node_modules_updater = node_modules.override {
            hash = pkgs.lib.fakeHash;
          };
        }
      );
    };
}
