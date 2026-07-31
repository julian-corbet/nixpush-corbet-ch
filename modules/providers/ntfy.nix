# modules/providers/ntfy.nix
#
# First-party ntfy provider: registers itself into
# `nixpush.providers.ntfy` and supplies `serverUrl` / `topic` /
# `tokenFile` as per-channel DEFAULTS for any channel with
# `provider = "ntfy"`, so a single-topic setup needs only this top-level
# block and `channels.<name>.provider = "ntfy";` -- no repeated
# `settings.serverUrl` on every channel.
#
# HOW: this module writes ONE flat value into
# `nixpush.providerDefaults.ntfy` -- a registry option owned by
# core (modules/default.nix) that does not depend on `channels` in any
# way -- and each channel submodule (also in modules/default.nix) reads
# that registry, keyed by its OWN sibling `provider` field, to compute
# its `settings`/`secretFile` defaults. This module never reads
# `nixpush.channels` at all.
#
# DON'T inject defaults via `lib.mapAttrs (...) cfg.channels` directly --
# that makes `channels`'s own value a function of `channels`'s own merged
# value, an actual circular definition (`infinite recursion encountered`
# at eval time). See the `providerDefaults` option's own comment in
# modules/default.nix for the full "why" if you're tempted to reintroduce
# that shape for a new provider.
{ lib, config, pkgs, ... }:

let
  cfg = config.nixpush;
  ntfyCfg = cfg.ntfy;
in
{
  options.nixpush.ntfy = {
    enable = lib.mkEnableOption "first-party ntfy provider for nixpush";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../pkgs/nixpush-provider-ntfy.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage <nixpush>/pkgs/nixpush-provider-ntfy.nix { }";
      description = "The nixpush-provider-ntfy executable package.";
    };

    serverUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://ntfy.sh";
      description = ''
        Default ntfy server for channels using this provider. A channel
        may override with `settings.serverUrl` for a self-hosted
        instance or a per-channel server.
      '';
    };

    topic = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Default topic. Leave `null` and set `settings.topic` per channel
        for multi-topic setups (e.g. a low-priority digest channel and a
        separate high-priority paging channel on the same server).
      '';
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Default path to a file containing `NTFY_TOKEN=<bearer token>`,
        for protected topics. Most setups need no token at all -- ntfy's
        own convention is to treat an unguessable topic name as the
        shared secret -- so this is optional and unset by default.
        Per-channel `secretFile` overrides this for that channel only.
      '';
    };
  };

  config = lib.mkIf ntfyCfg.enable {
    nixpush.providers.ntfy = ntfyCfg.package;

    nixpush.providerDefaults.ntfy = {
      settings =
        { serverUrl = ntfyCfg.serverUrl; }
        // lib.optionalAttrs (ntfyCfg.topic != null) { topic = ntfyCfg.topic; };
      secretFile = ntfyCfg.tokenFile;
    };
  };
}
