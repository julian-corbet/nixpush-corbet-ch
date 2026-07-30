# checks/default.nix
#
# Two kinds of test, plus a composed-host smoke check, combined into the flake outputs
# `nix flake check` runs:
#
#   EVAL-TIME assertion tests (checks/assertions.nix, folded into `eval-tests` below): each
#   evaluates a real configuration through NixOS's own eval-config.nix and asks whether
#   forcing `system.build.toplevel` fails. Nothing here runs a generated script -- this only
#   covers the durable/fallback option surface's own assertions, since that is the surface
#   this repo's fleet-watchdog generalization work actually added.
#
#   A BUILD-LEVEL behavioral proof (checks/behavior.nix, exported separately as
#   `behavior-proof`): the one thing eval-time checks cannot see -- the real `nixpush` CLI's
#   actual, repeated-invocation, stateful runtime behavior (a spool surviving independent
#   invocations, oldest-first drain, poison handling, fallback firing on its two trigger
#   conditions and never a third).
#
# PLUS `modules-evaluate`: the composed-host check (examples/host/configuration.nix), the
# same "every real, implemented option, once" shape nixwatch's own checks/default.nix uses.
{ pkgs, lib, nixpkgs, system, nixpushCoreModule, nixpushNtfyModule, nixpushDefaultModule }:

let
  assertionResults = import ./assertions.nix {
    inherit pkgs lib nixpkgs system nixpushCoreModule nixpushNtfyModule;
  };

  results = assertionResults;

  failed = builtins.filter (r: !r.ok) results;
  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;

  eval-tests =
    if failed != [ ]
    then
      throw ''
        nixpush eval-tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length results)}):
        ${report}
      ''
    else
    # Depending on `passedCount` forces `results`, so the tests genuinely run under
    # `nix flake check` rather than merely being defined.
      pkgs.runCommand "nixpush-eval-tests"
        { passedCount = toString (builtins.length results); }
        ''
          echo "all $passedCount nixpush eval tests passed"
          touch $out
        '';

  composedHost = lib.nixosSystem {
    inherit system;
    modules = [
      nixpushDefaultModule
      ../examples/host/configuration.nix
    ];
  };

  modules-evaluate =
    pkgs.writeText "nixpush-host-drvpath"
      (builtins.unsafeDiscardStringContext composedHost.config.system.build.toplevel.drvPath);
in
{
  inherit eval-tests modules-evaluate;
  behavior-proof = import ./behavior.nix { inherit pkgs lib system; };
}
