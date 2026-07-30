# modules/default.nix
#
# nixpush core: the `channels`/`providers` option schema, and the
# non-secret config render that `nixpush send` reads at invocation time
# (/etc/nixpush/channels.json). No provider is registered by this file --
# not even ntfy. See modules/providers/ntfy.nix for the first-party
# provider module, and flake.nix's `nixosModules.default` for the bundle
# most consumers actually want.
#
# TWO OPT-IN GUARANTEES LAYERED ON TOP OF THE SAME THIN CORE (both default OFF, both leave a
# channel that doesn't ask for them byte-for-byte unchanged -- see pkgs/nixpush.nix's
# `deliver_once` header for exactly where that "unchanged when off" contract is upheld, and
# checks/behavior.nix for the runtime proof of both, not just an eval-time one):
#
#   `channels.<name>.durable` -- a crash-safe on-disk spool. `nixpush send` on a durable
#   channel never attempts delivery inline: it atomically enqueues under `spoolDir` and
#   returns immediately, and a separate `nixpush flush` invocation -- wired to its own
#   systemd service+timer pair below, but ONLY rendered once at least one channel actually
#   sets `durable = true` -- drains every durable channel's spool oldest-enqueued-first,
#   retrying real delivery. A permanently-rejected (exit `3`) entry is moved aside into
#   `<channel>/poison/` instead of being retried forever, so one bad message can never wedge
#   every message enqueued behind it; a transient failure instead stops that channel's flush
#   run exactly where it is (preserving order) and is retried on the next tick. An outage
#   therefore DELAYS delivery, it never drops it, and it survives both this CLI's own process
#   exiting and a full host reboot, because the spool is nothing but ordinary files.
#
#   `channels.<name>.fallback` -- a channel to degrade to when THIS channel's delivery hits
#   either of exactly two conditions: its `secretFile` failed to unseal (configured but
#   unreadable -- the provider is never even invoked with missing credentials), or its
#   provider returned a hard, permanent rejection (exit `3`, genuinely attempted first). A
#   transient failure (anything else) never triggers this -- that is what retrying the SAME
#   channel is for (the caller's own retry policy, or a later `flush` tick if durable), not
#   switching destinations. Followed exactly ONE hop: the fallback channel's own `fallback`,
#   if it sets one, is never chased, so a page -> noise -> ??? chain can never form.
#
# See docs/rationale.md [4] and [5] for why each of these could live here at all without the
# README's "thin core, one delivery attempt, no daemon" thesis quietly becoming false for
# every consumer, not just the ones who opt in.
#
# EVAL SAFETY: `nixpush.channels.<name>.provider` is a free-form
# string, not `types.enum (attrNames cfg.providers)` -- providers can be
# registered by OTHER modules (modules/providers/ntfy.nix, or a
# community provider a consumer adds directly), and NixOS's module system
# resolves imports and options in one pass with no fixed ordering between
# them, so at the point this file's own option declarations are merged
# there is no guarantee every provider has registered itself into
# `nixpush.providers` yet. Validating the *string* is therefore
# deferred to `assertions` below (checked once `config` is fully
# resolved), and `providerExe` below never indexes `cfg.providers`
# directly for the same reason -- see the `cfg.providers.${...} or null`
# comment at its definition. This is the same "assert late, never dumbly
# index a maybe-missing key" discipline nixram's modules/default.nix
# documents under its own "EVAL SAFETY" comment.
{ lib, config, pkgs, ... }:

let
  cfg = config.nixpush;

  # Whether ANY channel opted into the on-disk spool -- gates the entire flush service/timer
  # pair and the spool directory's own tmpfiles rule below. A host with zero durable channels
  # gets NONE of that machinery rendered at all; this is the "opt-in, not a daemon for
  # everyone" line, drawn once, here.
  hasDurableChannel = lib.any (c: c.durable) (lib.attrValues cfg.channels);

  # Renders one channel's entry in /etc/nixpush/channels.json. Never
  # dereferences `secretFile` -- its path is recorded so the CLI knows
  # where to look, but the file itself is read fresh, at `send` time, by
  # the CLI (see pkgs/nixpush.nix) -- never by Nix, and never copied into
  # the store.
  renderChannel = name: channel:
    let
      # `or null` -- not `cfg.providers.${channel.provider}` -- so a
      # channel naming an unregistered provider fails with the friendly
      # `assertions` message below instead of a raw Nix "attribute
      # missing" error thrown mid-eval, before assertions get to speak.
      providerPkg = cfg.providers.${channel.provider} or null;
    in
    {
      provider = channel.provider;
      providerExe =
        if providerPkg != null
        then "${providerPkg}/bin/nixpush-provider-${channel.provider}"
        else null;
      settings = channel.settings;
      secretFile = channel.secretFile;
      defaultPriority = channel.defaultPriority;
      defaultTags = channel.defaultTags;
      durable = channel.durable;
      fallback = channel.fallback;
    };
in
{
  options.nixpush = {
    enable = lib.mkEnableOption "nixpush notification dispatch";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/nixpush.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage <nixpush>/pkgs/nixpush.nix { }";
      description = "The nixpush CLI package to install system-wide.";
    };

    defaultChannel = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Channel used by `nixpush send` when `--channel` is omitted.
        Must be a key present in `nixpush.channels` (asserted).
      '';
    };

    spoolDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nixpush/spool";
      description = ''
        Root directory for every `durable` channel's on-disk spool -- one subdirectory per
        channel name (e.g. `<spoolDir>/paging/`, with a `poison/` subdirectory under that for
        permanently-rejected entries). Only ever created (mode `0700`, `root:root`) when at
        least one channel actually sets `durable = true`; see that option's own description.
        Losing this directory's contents loses whatever notifications were still queued and
        not yet delivered -- it has no effect on any non-durable channel at all.
      '';
    };

    flushInterval = lib.mkOption {
      type = lib.types.str;
      default = "1m";
      description = ''
        How often the `nixpush-flush` systemd timer fires `nixpush flush` (systemd time-span
        syntax, e.g. `"30s"`, `"1min"`, `"5m"`) -- only rendered at all when at least one
        channel sets `durable = true`. Deliberately a single, module-wide cadence rather than
        a per-channel one (unlike nixwatch's per-check timers): flushing is not itself a
        monitored condition with its own staleness deadline, it is the retry loop for
        whatever channels opted into a spool, and they overwhelmingly share the same answer
        to "how promptly should a backlog drain once the outage clears". Give one channel a
        different cadence by wiring a private flush unit for it by hand if that default is
        ever genuinely wrong.
      '';
    };

    providers = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      default = { };
      description = ''
        Registry of provider name -> package. Each package must expose
        `bin/nixpush-provider-<name>` implementing the provider contract
        (see CONTRIBUTING.md). First-party provider modules (e.g.
        modules/providers/ntfy.nix) register themselves here
        automatically when enabled; third-party/community providers are
        added the same way, one line each:

          nixpush.providers.pushover = inputs.nixpush-pushover.packages.${pkgs.system}.default;
      '';
    };

    # Registry providers use to contribute per-channel option DEFAULTS
    # (settings/secretFile) for any channel bound to them -- e.g.
    # modules/providers/ntfy.nix sets `providerDefaults.ntfy.settings =
    # { serverUrl = ...; }` once, and every channel with
    # `provider = "ntfy"` inherits it via `mkDefault` below unless that
    # channel sets its own.
    #
    # WHY THIS EXISTS instead of the more obvious-looking
    # `nixpush.channels = lib.mapAttrs (...) cfg.channels`
    # (iterate the channels that already exist and inject defaults back
    # into them): that expression makes `channels`'s own value a
    # function of `channels`'s own merged value -- an actual, not just
    # apparent, circular definition (`infinite recursion encountered` at
    # eval time; caught by hand during the writing of this module, not
    # theoretical). `providerDefaults` is a SEPARATE option with no
    # dependency on `channels` at all, so a channel submodule reading it
    # (via a sibling option, `provider`, referencing an independent
    # registry) has nothing circular in its dependency graph:
    # channels[name] depends on providerDefaults depends on
    # nixpush.<provider>.* -- never back on channels.
    providerDefaults = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          settings = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
          };
          secretFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
          };
        };
      });
      default = { };
      internal = true;
      description = ''
        Populated by provider modules (e.g. modules/providers/ntfy.nix),
        not meant to be set directly in end-user configuration -- set
        `nixpush.<provider>.*` options instead.
      '';
    };

    channels = lib.mkOption {
      default = { };
      description = "Named delivery targets, each bound to exactly one provider.";
      type = lib.types.attrsOf (lib.types.submodule ({ config, ... }: {
        options = {
          provider = lib.mkOption {
            type = lib.types.str;
            description = "Key into `nixpush.providers` (asserted to exist).";
          };

          settings = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = ''
              Provider-specific, non-secret settings. Shape is opaque to
              core -- each provider documents its own keys. Rendered
              verbatim into /etc/nixpush/channels.json.
            '';
          };

          secretFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = ''
              Path to a runtime-readable file of shell `KEY=VALUE` lines
              (e.g. rendered by sops-nix / agenix) sourced into the
              provider's environment for this channel's `send` only.
              Read fresh per invocation; never written into the Nix
              store, never rendered into channels.json.
            '';
          };

          defaultPriority = lib.mkOption {
            type = lib.types.enum [ "min" "low" "default" "high" "urgent" ];
            default = "default";
            description = "Priority applied when `nixpush send` is called without `--priority`.";
          };

          defaultTags = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Tags applied when `nixpush send` is called without any `--tag`.";
          };

          durable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Opt in to a crash-safe, on-disk spool for this channel. `nixpush send` on a
              durable channel does not attempt delivery inline at all -- it atomically
              enqueues the notification into `nixpush.spoolDir` and returns immediately
              (`queued`, exit `0`), and a separate `nixpush flush` invocation (wired to a
              systemd timer by this module whenever ANY channel sets this -- see
              `flushInterval`) drains the spool oldest-enqueued-first, attempting real
              delivery for each entry in turn. An outage on this channel's destination
              therefore DELAYS delivery -- the entry stays spooled and is retried on the next
              flush -- but never silently drops it, surviving both this CLI's own process
              exiting and a full host restart, since the spool is nothing but ordinary files
              under `nixpush.spoolDir`.

              A message that comes back permanently rejected (exit `3`) during a flush is
              moved to `<spoolDir>/<channel>/poison/` instead of being retried forever -- see
              `nixpush flush`'s own reference in README.md -- so one bad message can never
              wedge every message enqueued behind it.

              Default `false`: `nixpush send` on a non-durable channel is BYTE-FOR-BYTE the
              same synchronous, one-attempt, 0/3/other codepath nixpush has always had.
              Turning this on is a real behavior change for THIS channel's callers -- a
              `queued` success no longer means delivered -- so it is opt-in per channel,
              deliberately, never global.
            '';
          };

          fallback = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Name of another `nixpush.channels.<name>` to degrade to when THIS channel's
              delivery hits one of exactly two conditions: (a) its `secretFile` is set but
              not readable at send time ("failed to unseal" -- e.g. sops-nix/agenix did not
              render it, so the provider is never even invoked with missing credentials), or
              (b) its provider exits `3` (permanently rejected -- a real, provider-classified
              hard error, genuinely attempted first, not a network blip). A THIRD kind of
              failure -- anything transient, exit code neither `0` nor `3` -- never triggers
              this: retrying the SAME channel (via the caller's own retry policy, or a later
              `nixpush flush` tick if this channel is `durable`) is the correct response to a
              blip, not switching destinations.

              Followed exactly ONE hop: the fallback channel's OWN `fallback` (if it sets
              one) is never chased, so a page -> noise -> ??? chain can never form, and
              there is nothing to prove acyclic beyond simple self-reference (asserted
              below).

              `null` (default): unchanged from nixpush's original behavior -- a channel with
              an unreadable secretFile or a hard-rejecting provider fails exactly as before
              (exit `2` for the former, exit `3` for the latter); nothing degrades anywhere.
            '';
          };
        };

        # Inherits this channel's provider's registered defaults (see
        # `providerDefaults` above) unless the channel sets its own --
        # `config.provider` here is THIS submodule instance's own,
        # already-resolved `provider` field (a sibling option, safe to
        # depend on); `cfg` is the OUTER `nixpush` config,
        # captured via closure from the top of this file -- a different,
        # non-circular option (`providerDefaults`), not `channels` itself.
        config =
          let
            pd = cfg.providerDefaults.${config.provider} or null;
          in
          lib.mkIf (pd != null) {
            settings = lib.mapAttrs (_key: lib.mkDefault) pd.settings;
            secretFile = lib.mkIf (pd.secretFile != null) (lib.mkDefault pd.secretFile);
          };
      }));
    };

    # Nix-level helper surface -- see lib/default.nix. Exposed here (not
    # just as a flake output) so a consuming module can write
    # `config.nixpush.lib.mkSendCommand { ... }` without an
    # extra `inputs.nixpush.lib` plumb-through. `types.raw` is
    # deliberate: this attrset carries a function value, which the
    # module system cannot usefully type-check or merge -- `raw` opts
    # out of both and just carries the value through.
    lib = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      default = import ../lib/default.nix { inherit lib; };
      description = "Nix-level helpers for wiring nixpush sends into other modules' units (currently: `mkSendCommand`).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      (lib.mapAttrsToList
        (name: channel: {
          assertion = lib.hasAttr channel.provider cfg.providers;
          message = ''
            nixpush.channels.${name}.provider is set to
            "${channel.provider}", but no such key exists in
            nixpush.providers. Registered providers: ${
              if cfg.providers == { }
              then "(none -- did you forget nixpush.ntfy.enable, or to add a community provider to nixpush.providers?)"
              else lib.concatStringsSep ", " (lib.attrNames cfg.providers)
            }
          '';
        })
        cfg.channels)
      ++ (lib.mapAttrsToList
        (name: channel: {
          assertion = channel.fallback == null || channel.fallback != name;
          message = ''
            nixpush.channels.${name}.fallback references itself -- a channel cannot degrade
            to its own destination.
          '';
        })
        cfg.channels)
      ++ (lib.mapAttrsToList
        (name: channel: {
          assertion = channel.fallback == null || lib.hasAttr channel.fallback cfg.channels;
          message = ''
            nixpush.channels.${name}.fallback is set to
            "${toString channel.fallback}", but no such key exists in nixpush.channels.
            Declared channels: ${
              if cfg.channels == { }
              then "(none)"
              else lib.concatStringsSep ", " (lib.attrNames cfg.channels)
            }.
          '';
        })
        cfg.channels)
      ++ [
        {
          assertion = cfg.defaultChannel == null || lib.hasAttr cfg.defaultChannel cfg.channels;
          message = ''
            nixpush.defaultChannel is set to
            "${toString cfg.defaultChannel}", but no such key exists in
            nixpush.channels.
          '';
        }
      ];

    environment.etc."nixpush/channels.json" = {
      mode = "0440";
      group = "nixpush";
      text = builtins.toJSON {
        defaultChannel = cfg.defaultChannel;
        spoolDir = cfg.spoolDir;
        channels = lib.mapAttrs renderChannel cfg.channels;
      };
    };

    # Exists so a provider or a future least-privilege caller can be
    # granted read access to channels.json without granting root.
    # Nothing runs as this group by default in v1 -- the CLI is normally
    # invoked as root (systemd ExecStopPost=, OnFailure=, root cron) and
    # root already reads mode-0440 files regardless of group.
    users.groups.nixpush = { };

    environment.systemPackages = [ cfg.package ];

    # Everything below this point exists ONLY when at least one channel opted into
    # `durable` -- a host with no durable channels gets no spool directory, no flush
    # service, no flush timer, nothing. This is the "opt-in, never a daemon for everyone"
    # line made concrete: `nixpush-flush` is a `Type = "oneshot"` unit driven entirely by
    # its timer, the same shape nixwatch uses for each of ITS checks, never a
    # long-running process of its own.
    systemd.tmpfiles.rules = lib.mkIf hasDurableChannel [
      "d ${cfg.spoolDir} 0700 root root - -"
    ];

    systemd.services.nixpush-flush = lib.mkIf hasDurableChannel {
      description = "nixpush: flush every durable channel's on-disk spool";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${cfg.package}/bin/nixpush flush";
      };
    };

    systemd.timers.nixpush-flush = lib.mkIf hasDurableChannel {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Fires promptly after boot too -- this is what "surviving a host restart" actually
        # means in practice: whatever was still spooled when the host went down gets a real
        # delivery attempt again soon after it comes back, not only `flushInterval` later.
        OnBootSec = "10s";
        OnUnitActiveSec = cfg.flushInterval;
        # Catches up a missed tick across a period the HOST itself was down, same as
        # nixwatch's own timers -- a spool that survives a restart is only half the
        # guarantee if the timer that's supposed to drain it doesn't reliably fire again
        # once it's back.
        Persistent = true;
      };
    };
  };
}
