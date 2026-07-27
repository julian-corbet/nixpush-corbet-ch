# modules/default.nix
#
# nixpush core: the `channels`/`providers` option schema, and the
# non-secret config render that `nixpush send` reads at invocation time
# (/etc/nixpush/channels.json). No provider is registered by this file --
# not even ntfy. See modules/providers/ntfy.nix for the first-party
# provider module, and flake.nix's `nixosModules.default` for the bundle
# most consumers actually want.
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
  };
}
