# nixpush

A stateless, provider-agnostic notification-dispatch mechanism for NixOS: a thin core module
that defines named `channels` bound to pluggable `providers`, plus a synchronous CLI
(`nixpush send ...`) that performs exactly one delivery attempt and reports the outcome via a
3-class exit code.

The problem this solves: you shouldn't have to rewrite every module, script, and systemd unit
that wants to alert someone just to swap notification backends. Most NixOS setups end up with
alerting logic hand-rolled per service — a `curl` call to one push service buried in a
`healthCheck` script here, a different `curl` call to a different service in an
`ExecStopPost=` there — so switching from, say, a public ntfy topic to a self-hosted Gotify
instance means hunting down and editing every place that ever fired an alert. nixpush moves
that decision to one place: modules and scripts call `nixpush send --channel alerts "..."`
(or the same thing via `--channel`'s default, or the `mkSendCommand` Nix helper) and never
know or care what actually receives it. Repoint `channels.alerts.provider` and every caller's
behavior changes with it — nothing that calls `nixpush send` has to change at all.

There is no daemon and no persistent queue in core v1. A provider is a small executable that
speaks one JSON-in/exit-code-out contract (see [CONTRIBUTING.md](CONTRIBUTING.md)), so
community providers (pushover, gotify, matrix, …) can be written in any language with zero
dependency on nixpush internals. The first-party `ntfy` provider — [pkgs/nixpush-provider-ntfy.nix](pkgs/nixpush-provider-ntfy.nix)
— is a real, working `curl`+`jq` implementation, not a stub.

## Quickstart

```nix
# flake.nix (consumer side)
{
  inputs.nixpush.url = "github:example-org/nixpush-example-com";

  outputs = { self, nixpkgs, nixpush }: {
    nixosConfigurations.example-host = nixpkgs.lib.nixosSystem {
      modules = [
        nixpush.nixosModules.default   # core + first-party ntfy provider
        ./configuration.nix
      ];
    };
  };
}
```

```nix
# configuration.nix
services.nixpush = {
  enable = true;
  defaultChannel = "alerts";

  ntfy = {
    enable = true;
    serverUrl = "https://ntfy.example.org";   # or the public https://ntfy.sh
  };

  channels.alerts = {
    provider = "ntfy";
    settings.topic = "REPLACE_ME_UNGUESSABLE_TOPIC";
    defaultPriority = "high";
    defaultTags = [ "rotating_light" ];
  };

  channels.digest = {
    provider = "ntfy";
    settings.topic = "REPLACE_ME_LOWPRIO_TOPIC";
    defaultPriority = "low";
  };

  # Optional: a protected topic reading its token from a runtime secret
  # file (e.g. rendered by sops-nix), never embedded in the Nix store.
  channels.paging = {
    provider = "ntfy";
    settings.topic = "REPLACE_ME_PAGE_TOPIC";
    secretFile = "/run/secrets/nixpush-paging.env";  # contains NTFY_TOKEN=...
    defaultPriority = "urgent";
  };
};
```

```console
$ nixpush channels
alerts   -> ntfy
digest   -> ntfy
paging   -> ntfy

$ nixpush doctor
alerts:  ok
digest:  ok
paging:  ok

$ nixpush send --tag disk_full "root filesystem above 90% on example-host"
delivered (http 200)

$ nixpush send --channel digest --priority low --json "nightly backup completed"
{"status":"delivered","channel":"digest","provider":"ntfy","http_status":200}

$ echo $?
0
```

Wired into another unit, with retry left to systemd rather than nixpush:

```nix
systemd.services.example-batch-job = {
  serviceConfig = {
    ExecStopPost = "${config.services.nixpush.lib.mkSendCommand {
      channel = "paging"; priority = "urgent";
    }} 'example-batch-job failed on %H'";
    Restart = "on-failure";
    RestartSec = "30s";
  };
};
```

## Options

`services.nixpush.*` (core — [modules/default.nix](modules/default.nix)):

- `enable` — turn nixpush on: renders `/etc/nixpush/channels.json` and installs the CLI.
- `package` — the `nixpush` CLI package (default: this repo's own).
- `defaultChannel` — channel used by `nixpush send` when `--channel` is omitted. Must name a
  key in `channels` (asserted); leaving both unset is a hard error — nixpush never silently
  picks a channel.
- `providers` — registry of provider name → package (`attrsOf package`). First-party provider
  modules register themselves here when enabled; add a community provider with one line.
- `channels.<name>.provider` — key into `providers` (asserted to exist).
- `channels.<name>.settings` — provider-specific, non-secret settings (`attrsOf str`);
  rendered verbatim into `channels.json`. Shape is opaque to core, each provider documents its
  own keys.
- `channels.<name>.secretFile` — path to a runtime-readable `KEY=VALUE` file (sops-nix,
  agenix, …) sourced into the provider's environment for that channel's `send` only. Read
  fresh per invocation; never rendered into `channels.json`, never copied into the store.
- `channels.<name>.defaultPriority` — one of `min` `low` `default` `high` `urgent`; applied
  when `send` is called without `--priority`.
- `channels.<name>.defaultTags` — tags applied when `send` is called without any `--tag`.
- `lib.mkSendCommand { ... }` — Nix helper producing a ready-to-embed shell command string for
  wiring a send into another module's unit (`ExecStopPost=`, `OnFailure=`, …); see
  [lib/default.nix](lib/default.nix).

`services.nixpush.ntfy.*` (first-party provider — [modules/providers/ntfy.nix](modules/providers/ntfy.nix)):

- `enable` — register the `ntfy` provider and enable its per-channel defaults below.
- `package` — the `nixpush-provider-ntfy` executable package.
- `serverUrl` — default ntfy server (default `https://ntfy.sh`); a channel may override with
  `settings.serverUrl`.
- `topic` — default topic; leave `null` and set `settings.topic` per channel for multi-topic
  setups (a chatty digest channel and a separate paging channel on the same server, say).
- `tokenFile` — default path to a `NTFY_TOKEN=<bearer token>` file for protected topics. Most
  setups need none at all — ntfy's own convention treats an unguessable topic name as the
  shared secret. Per-channel `secretFile` overrides this for that channel only.

## Provider contract

See [CONTRIBUTING.md](CONTRIBUTING.md) — the stdin JSON envelope, the environment variables a
provider can read, and the exact 0/3/other exit-code split every provider (first- or
third-party) implements. [pkgs/nixpush-provider-ntfy.nix](pkgs/nixpush-provider-ntfy.nix) is
the reference implementation.

## CLI reference

```
nixpush send [--channel NAME] [--title TITLE] [--priority min|low|default|high|urgent]
             [--tag TAG]... [--click URL] [--attach URL] [--action LABEL=URL]...
             [--delay DURATION] [--timeout SECONDS] [--json] MESSAGE

nixpush channels [--names-only]
    List configured channel names and their bound provider.

nixpush doctor [--channel NAME]
    Dry-run: validates config (channel exists, provider resolves,
    settings pass the provider's `check-settings`) without sending.
    Exits nonzero if any checked channel is misconfigured -- wire into
    ExecStartPre= or CI.
```

`--channel` is optional if `services.nixpush.defaultChannel` is set; omitting both is a hard
error. `MESSAGE` is the only required argument for `send`. Exit codes mirror the provider
contract exactly: `0` delivered, `3` permanently rejected, `2` usage/config error (from the
CLI itself, before any provider ran), anything else transient/unknown — directly usable in
shell (`if ! nixpush send ...; then ...`) and directly wireable into systemd `ExecStartPost=`
/ `OnFailure=` / `Restart=on-failure` without glue code. See
[docs/faq.md](docs/faq.md#why-three-exit-code-classes-03other-instead-of-plain-successfailure)
for why three classes.

## Repository layout

| Path | What |
|---|---|
| `flake.nix` | `nixosModules.core` / `.ntfy-provider` / `.default`; `packages.nixpush`, `.nixpush-provider-ntfy` |
| `modules/default.nix` | Core option schema + channel rendering |
| `modules/providers/ntfy.nix` | ntfy provider options + registration |
| `pkgs/nixpush.nix` | Core CLI derivation |
| `pkgs/nixpush-provider-ntfy.nix` | First-party ntfy provider derivation |
| `lib/nixpush.sh` | POSIX-sh `nixpush_send()` helper |
| `lib/default.nix` | `mkSendCommand` Nix helper |
| `docs/` | `faq.md`, `rationale.md`, `index.md` |
| `experiments/` | Throwaway trials, dated Question/Hypothesis/Method/Result/Status entries |
| `studies/` | Write-ups that changed a decision |
| `CONTRIBUTING.md` | The provider contract, concretely |
| `LICENSE` | MIT |

## Non-goals & future direction

Explicitly out of scope for v1 — the caller's responsibility, by design:

- Retry/backoff/queueing across process restarts.
- Delivery-status querying after the `send` process has exited.
- Dedup/coalescing/rate-limiting of repeated sends.
- Fan-out to multiple channels in a single `send` call.

Deferred, not discarded: a daemon+durable-spool design remains the right answer for a caller
that needs delivery to survive *its own* crash or a host reboot between "alert fired" and
"bytes left the box," not just a network blip. That's a natural `nixpush-daemon` package for a
future v2: same provider contract unchanged (stdin JSON / env settings / 0-3-other exit
codes), same `channels`/`providers` core options unchanged, with `nixpush send` gaining a
`--durable` flag that hands off to the daemon's atomic-write-then-rename spool instead of
calling the provider inline. Because the provider contract doesn't change, every provider
written against v1 keeps working unmodified under a v2 daemon. See
[docs/rationale.md \[1\]](docs/rationale.md#1-stateless-synchronous-cli-no-daemon-no-queue-core-v1)
for the full reasoning behind starting here.

## Related projects

nixpush is one of several small, independently-usable open-source projects sharing a common
design system: **nixram** (memory-pressure tuning), **nixarch** (declarative Arch/CachyOS
workstations), and **nixnet** (declarative multi-uplink networking), among others. nixpush's
own niche is purely notification dispatch — usable alongside any of them, or standalone.

## License

MIT.
