{
  description = "Ontology language and PostgreSQL compiler";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      eachSystem = nixpkgs.lib.genAttrs systems;
      environment = system:
        let
          pkgs = import nixpkgs { inherit system; };
          compiler = pkgs.haskellPackages.ghcWithPackages (hs: with hs; [
            containers megaparsec mtl scientific time aeson bytestring text
          ]);
        in { inherit pkgs compiler; };
    in {
      packages = eachSystem (system:
        let inherit (environment system) pkgs compiler;
        in {
          default = pkgs.stdenv.mkDerivation {
            pname = "ontology";
            version = "0.1.0";
            src = self;
            nativeBuildInputs = [ compiler pkgs.gnumake ];
            buildPhase = "make";
            installPhase = "make install PREFIX=$out";
          };
        });
      apps = eachSystem (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/ontology";
        };
      });
      devShells = eachSystem (system:
        let inherit (environment system) pkgs compiler;
        in {
          default = pkgs.mkShell {
            packages = [ compiler pkgs.cabal-install pkgs.gnumake pkgs.postgresql_16 pkgs.python3 pkgs.nodejs_22 ];
            GHC = "${compiler}/bin/ghc";
          };
        });
      checks = eachSystem (system:
        let inherit (environment system) pkgs compiler;
        in {
          unit = pkgs.stdenv.mkDerivation {
            pname = "ontology-checks";
            version = "0.1.0";
            src = self;
            nativeBuildInputs = [ compiler pkgs.gnumake pkgs.python3 ];
            buildPhase = "make test";
            installPhase = "touch $out";
          };
        });
    };
}

