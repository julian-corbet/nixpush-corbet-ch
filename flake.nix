{
  description = "A stateless, provider-agnostic notification-dispatch mechanism for NixOS: named channels bound to pluggable providers, plus a synchronous `nixpush send` CLI with a 3-class exit code. No daemon, no queue in core -- see README.md.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      # Core: the `channels`/`providers` option schema + the
      # /etc/nixpush/channels.json render. No provider registered.
      nixosModules.core = import ./modules/default.nix;

      # First-party ntfy provider: registers itself into
      # `nixpush.providers.ntfy` and supplies per-channel
      # defaults (serverUrl/topic/tokenFile). Needs `nixosModules.core`
      # imported too (or via `nixosModules.default` below, which bundles
      # both).
      nixosModules.ntfy-provider = import ./modules/providers/ntfy.nix;

      # core + first-party ntfy provider, bundled -- what the README's
      # Quickstart and most single-provider consumers actually want.
      nixosModules.default = {
        imports = [ self.nixosModules.core self.nixosModules.ntfy-provider ];
      };

      packages = forAllSystems (system:
        let pkgs = pkgsFor system; in
        {
          nixpush = pkgs.callPackage ./pkgs/nixpush.nix { };
          nixpush-provider-ntfy = pkgs.callPackage ./pkgs/nixpush-provider-ntfy.nix { };
          default = self.packages.${system}.nixpush;
        });

      checks = forAllSystems (system:
        import ./checks {
          pkgs = pkgsFor system;
          inherit lib nixpkgs system;
          nixpushCoreModule = self.nixosModules.core;
          nixpushNtfyModule = self.nixosModules.ntfy-provider;
          nixpushDefaultModule = self.nixosModules.default;
        });

      # Nix-level `mkSendCommand` helper -- also reachable as
      # `config.nixpush.lib.mkSendCommand` once
      # `nixosModules.core` is imported, without this extra plumb-through.
      lib = import ./lib/default.nix { inherit lib; };

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
