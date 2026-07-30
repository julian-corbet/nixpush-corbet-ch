# checks/assertions.nix
#
# Eval-time checks for modules/default.nix's TWO new assertions (fallback self-reference,
# fallback naming an undeclared channel): each evaluates a real configuration through NixOS's
# own eval-config.nix and asks whether forcing `system.build.toplevel` fails. Nothing here
# runs anything -- assertions are an eval-time property (NixOS enforces `config.assertions`
# when `system.build.toplevel` is forced, not on a bare read of the list). The pre-existing
# `provider`/`defaultChannel` assertions are not re-proven here -- they predate this file and
# were not touched by the durable-spool or fallback work; this file's job is the NEW surface
# only.
{ pkgs, lib, nixpkgs, system, nixpushCoreModule, nixpushNtfyModule }:

let
  bareStubs = {
    boot.loader.grub.enable = false;
    fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
    system.stateVersion = "25.05";
  };

  base = {
    nixpush.enable = true;
    nixpush.ntfy.enable = true;
    nixpush.channels.a = { provider = "ntfy"; settings.topic = "example-a"; };
  };

  # `extraModules` is a LIST of additional modules, merged by NixOS's own module system
  # (never a raw Nix `//`, which would shallow-merge the WHOLE `nixpush` attribute and
  # silently discard `base`'s `nixpush.enable`/`.ntfy.enable`/`.channels.a` -- a real mistake
  # caught while writing this file, not theoretical: every "should build fine" case appeared
  # to pass with a `//`-merged config too, but only because nixpush had gone silently
  # disabled, not because the assertion under test genuinely held).
  evalNixpush = extraModules:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system;
      modules = [ nixpushCoreModule nixpushNtfyModule bareStubs base ] ++ extraModules;
    }).config;

  buildFails = extraModules:
    !(builtins.tryEval (builtins.seq (evalNixpush extraModules).system.build.toplevel true)).success;

  check = name: ok: detail: { inherit name ok detail; };
in
[
  (check "checks/fallback-self-reference-fails-the-build"
    (buildFails [{ nixpush.channels.a.fallback = "a"; }])
    "expected a channel naming itself as its own fallback to fail the build, but it succeeded")

  (check "checks/fallback-unknown-channel-fails-the-build"
    (buildFails [{ nixpush.channels.a.fallback = "does-not-exist"; }])
    "expected a fallback naming an undeclared channel to fail the build, but it succeeded")

  (check "checks/fallback-valid-reference-builds-fine"
    (
      !(buildFails [{
        nixpush.channels.a.fallback = "b";
        nixpush.channels.b = { provider = "ntfy"; settings.topic = "example-b"; };
      }])
    )
    "a fallback naming another, real, declared channel should never fail the build on its own")

  (check "checks/fallback-unset-builds-fine"
    (!(buildFails [ ]))
    "leaving fallback unset (null, the default) should never fail the build on its own")

  (check "checks/durable-channel-builds-fine"
    (!(buildFails [{ nixpush.channels.a.durable = true; }]))
    "a channel with durable = true should never fail the build on its own")

  (check "checks/durable-channel-renders-flush-service-and-timer"
    (
      let cfg = (evalNixpush [{ nixpush.channels.a.durable = true; }]).systemd; in
      cfg.services ? nixpush-flush && cfg.timers ? nixpush-flush
    )
    "expected the nixpush-flush service+timer pair to be rendered once any channel sets durable = true")

  (check "checks/no-durable-channel-renders-no-flush-service-or-timer"
    (
      let cfg = (evalNixpush [ ]).systemd; in
      !(cfg.services ? nixpush-flush) && !(cfg.timers ? nixpush-flush)
    )
    "expected NO nixpush-flush service or timer when no channel sets durable = true -- this is the 'no daemon for anyone who doesn't opt in' guarantee")
]
