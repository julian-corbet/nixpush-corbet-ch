# nixpush

A stateless-by-default, provider-agnostic notification-dispatch mechanism for NixOS: a thin
core module that defines named `channels` bound to pluggable `providers`, a synchronous CLI
(`nixpush send ...`) that performs exactly one delivery attempt and reports the outcome via a
3-class exit code, and two things a channel can opt into WITHOUT changing that default for
anyone else: a crash-safe on-disk spool (`durable = true`, see
[Durable channels](#durable-channels-a-crash-safe-spool)) and a fallback destination
(`fallback = "..."`, see [Channel fallback](#channel-fallback-unseal-failure-vs-hard-rejection))
for when a secret fails to unseal or a provider hard-rejects.

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

There is no daemon anywhere in nixpush, and no channel is queued unless it explicitly opts in
(`durable = true`) — the default remains exactly one synchronous delivery attempt per `send`,
byte-for-byte unchanged from before either opt-in feature existed. A provider is a small
executable that speaks one JSON-in/exit-code-out contract (see
[CONTRIBUTING.md](CONTRIBUTING.md)), so community providers (pushover, gotify, matrix, …) can
be written in any language with zero dependency on nixpush internals. The first-party `ntfy`
provider — [pkgs/nixpush-provider-ntfy.nix](pkgs/nixpush-provider-ntfy.nix) — is a real,
working `curl`+`jq` implementation, not a stub.

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
nixpush = {
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
    ExecStopPost = "${config.nixpush.lib.mkSendCommand {
      channel = "paging"; priority = "urgent";
    }} 'example-batch-job failed on %H'";
    Restart = "on-failure";
    RestartSec = "30s";
  };
};
```

## Durable channels: a crash-safe spool

Every channel defaults to nixpush's original shape: `send` makes exactly one delivery attempt
and returns. Setting `durable = true` on a channel changes that FOR THAT CHANNEL ONLY: `send`
no longer attempts delivery inline at all — it atomically enqueues the notification under
`nixpush.spoolDir` and returns immediately (`queued`, exit `0`), and a separate `nixpush flush`
invocation drains it later. An outage on that channel's destination therefore DELAYS delivery
instead of dropping it, and the delay survives both this CLI's own process exiting and a full
host reboot, because the spool is nothing but ordinary files.

```nix
nixpush.channels.paging = {
  provider = "ntfy";
  secretFile = "/run/secrets/nixpush-paging.env";
  defaultPriority = "urgent";
  durable = true;
};

nixpush.flushInterval = "30s";  # default "1m" -- how often nixpush-flush.timer fires
```

Whenever at least one channel sets `durable = true`, this module renders a `nixpush-flush`
systemd service (`Type = "oneshot"`, never a resident process) and timer pair that calls
`nixpush flush` on that cadence — `OnBootSec = "10s"` so anything still spooled from before a
crash or reboot gets a real delivery attempt again promptly, `Persistent = true` so a missed
tick across a period the HOST itself was down still fires once it's back. A host with zero
durable channels gets neither unit at all — this is opt-in, per channel, never a daemon
foisted on a consumer who never asked for one.

```console
$ nixpush send --channel paging "disk usage above threshold"
$ echo $?
0

$ ls /var/lib/nixpush/spool/paging/
20261120153045123456789-4821-7734.json

$ nixpush flush --channel paging
$ ls /var/lib/nixpush/spool/paging/
(empty -- delivered)
```

**Oldest-first, and poison-message handling.** `flush` drains a channel's spool in
enqueue order (the timestamp-based filenames sort exactly that way). A message that comes
back permanently rejected (provider exit `3`) is moved aside into `<channel>/poison/` instead
of being retried forever — one bad message can never wedge every message enqueued behind it. A
transient failure instead stops that channel's drain exactly where it is, leaving every
remaining message (including the one that just failed) spooled in order for the next flush —
different channels are independent, so one channel's outage never blocks another's. See
[docs/rationale.md \[4\]](docs/rationale.md#4-an-opt-in-per-channel-spool-not-a-repo-wide-daemon)
for why this can live in nixpush core at all without its "thin core, no daemon" thesis quietly
becoming false for every consumer, and `checks/behavior.nix` for all of the above proven at
runtime — a real spool, a real poisoned message, real independent flush invocations standing
in for a crash-and-restart — not just asserted at eval time.

**Honest limit, stated plainly:** there is no size cap or eviction policy on a channel's own
spool — an outage that never clears grows it without bound. See
[Non-goals & future direction](#non-goals--future-direction) below.

## Channel fallback: unseal failure vs. hard rejection

A channel binds to exactly one provider destination — but a paging channel's whole point is
that it must not silently go dark. Setting `fallback = "other-channel";` degrades to `other-channel`
on exactly two conditions:

- **The channel's `secretFile` failed to unseal** — configured but unreadable at send time
  (sops-nix/agenix did not render it, most commonly). The primary's provider is never even
  invoked with missing credentials.
- **The channel's provider returned a hard, permanent rejection** (exit `3`) — genuinely
  attempted first, and genuinely said no.

A THIRD kind of failure — anything transient, exit code neither `0` nor `3` — never triggers
this. A blip might succeed on a plain retry against the very same destination; degrading to a
different one over a blip would silently reroute the alert somewhere an operator checking the
primary topic would never think to look. See
[docs/rationale.md \[5\]](docs/rationale.md#5-fallback-triggers-on-unseal-failure-and-hard-rejection-only-never-on-transient)
for the full reasoning.

```nix
nixpush.channels.paging = {
  provider = "ntfy";
  secretFile = "/run/secrets/nixpush-paging.env";
  defaultPriority = "urgent";
  fallback = "ops-noise";  # degrade here, never on a transient blip
};

nixpush.channels.ops-noise = {
  provider = "ntfy";
  secretFile = "/run/secrets/nixpush-noise.env";
};
```

```console
$ nixpush send --channel paging --json "paging secret failed to unseal on the host"
{"status":"delivered","channel":"ops-noise","provider":"ntfy","http_status":200,"fallbackFrom":"paging","fallbackReason":"unseal"}
```

Followed exactly **one hop**: `ops-noise`'s own `fallback`, if it set one, would never be
chased — a page → noise → ??? chain can never form. `fallback` defaults to `null`; leaving it
unset means a channel with an unreadable `secretFile` or a hard-rejecting provider fails
exactly as it always did (exit `2` or `3` respectively) — nothing degrades anywhere.
`durable` and `fallback` compose freely (a durable channel's `flush` applies the exact same
fallback logic per spooled message that `send`'s inline path does).

## Options

`nixpush.*` (core — [modules/default.nix](modules/default.nix)):

- `enable` — turn nixpush on: renders `/etc/nixpush/channels.json` and installs the CLI.
- `package` — the `nixpush` CLI package (default: this repo's own).
- `defaultChannel` — channel used by `nixpush send` when `--channel` is omitted. Must name a
  key in `channels` (asserted); leaving both unset is a hard error — nixpush never silently
  picks a channel.
- `providers` — registry of provider name → package (`attrsOf package`). First-party provider
  modules register themselves here when enabled; add a community provider with one line.
- `spoolDir` — root directory for every `durable` channel's on-disk spool (default
  `/var/lib/nixpush/spool`). Only ever created when at least one channel sets
  `durable = true`; see [Durable channels](#durable-channels-a-crash-safe-spool).
- `flushInterval` — how often the `nixpush-flush` timer fires `nixpush flush` (systemd
  time-span syntax, default `"1m"`); only rendered when at least one channel sets
  `durable = true`.
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
- `channels.<name>.durable` — opt in to a crash-safe on-disk spool for this channel (default
  `false`). See [Durable channels](#durable-channels-a-crash-safe-spool).
- `channels.<name>.fallback` — name of another channel to degrade to on an unseal failure or a
  hard rejection (default `null`, meaning no fallback). See
  [Channel fallback](#channel-fallback-unseal-failure-vs-hard-rejection).
- `lib.mkSendCommand { ... }` — Nix helper producing a ready-to-embed shell command string for
  wiring a send into another module's unit (`ExecStopPost=`, `OnFailure=`, …); see
  [lib/default.nix](lib/default.nix).

`nixpush.ntfy.*` (first-party provider — [modules/providers/ntfy.nix](modules/providers/ntfy.nix)):

- `enable` — register the `ntfy` provider and enable its per-channel defaults below.
- `package` — the `nixpush-provider-ntfy` executable package.
- `serverUrl` — default ntfy server (default `https://ntfy.sh`); a channel may override with
  `settings.serverUrl`.
- `topic` — default topic; leave `null` and set `settings.topic` per channel for multi-topic
  setups (a chatty digest channel and a separate paging channel on the same server, say).
- `tokenFile` — default path to a `NTFY_TOKEN=<bearer token>` file for protected topics. Most
  setups need none at all — ntfy's own convention treats an unguessable topic name as the
  shared secret. Per-channel `secretFile` overrides this for that channel only.

**Keeping the topic itself out of the Nix store:** `settings.topic` is plain Nix-eval-time
config, rendered verbatim into `/etc/nixpush/channels.json` — fine when the topic is a
non-secret routing key, but *not* fine when the topic name itself is the credential (ntfy's
"unguessable topic name as shared secret" convention, used for e.g. paging/alerting channels
where you don't want the topic readable from the store regardless of `/etc` file mode). For
that case, set `NTFY_TOPIC=<topic>` in the channel's `secretFile` — same file, same mechanism
as `NTFY_TOKEN`, sourced fresh into the provider's environment per-invocation and never
written to the store. `NTFY_TOPIC` wins over `settings.topic` when both are present, so
`settings.topic` can simply be omitted for a fully secret-sourced channel:

```nix
channels.paging = {
  provider = "ntfy";
  secretFile = "/run/secrets/nixpush-paging.env";  # contains NTFY_TOPIC=... and/or NTFY_TOKEN=...
  defaultPriority = "urgent";
};
```

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

nixpush flush [--channel NAME] [--json]
    Drain every `durable` channel's on-disk spool (or just the one named by
    --channel), oldest-enqueued-first, attempting real delivery for each
    entry. A permanently-rejected entry is moved to <channel>/poison/ and
    does not block the rest of that channel's queue; a transient failure
    stops that channel's drain exactly where it is (order preserved) and
    is retried on the next flush. Exits 0 only if every attempted
    channel's queue was left fully drained this run. Wired to its own
    systemd timer whenever at least one channel sets durable = true (see
    `flushInterval`) -- not meant to be run by hand under normal use,
    though doing so is harmless.
```

`--channel` is optional if `nixpush.defaultChannel` is set; omitting both is a hard
error. `MESSAGE` is the only required argument for `send`. Exit codes mirror the provider
contract exactly: `0` delivered (or, on a `durable` channel, durably QUEUED for later
delivery — see [Durable channels](#durable-channels-a-crash-safe-spool)), `3` permanently
rejected, `2` usage/config error (from the CLI itself, before any provider ran), anything else
transient/unknown — directly usable in shell (`if ! nixpush send ...; then ...`) and directly
wireable into systemd `ExecStartPost=` / `OnFailure=` / `Restart=on-failure` without glue code.
See
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
| `examples/host/` | A minimal composed system exercising every implemented option, including a `durable` + `fallback` channel — used by `nix flake check` |
| `checks/assertions.nix` | Eval-time build-fail/build-succeed tests for the `fallback` self-reference and unknown-channel assertions, both directions |
| `checks/behavior.nix` | A build-level proof that actually RUNS the real `nixpush` CLI against fake providers: a spool surviving independent invocations, oldest-first drain, poison handling, and fallback firing on each of its two trigger conditions (and never a third) |
| `experiments/` | Throwaway trials, dated Question/Hypothesis/Method/Result/Status entries |
| `studies/` | Write-ups that changed a decision |
| `CONTRIBUTING.md` | The provider contract, concretely |
| `LICENSE` | MIT |

## Non-goals & future direction

Still explicitly out of scope for core — the caller's responsibility, by design:

- Delivery-status querying after a `send`/`flush` process has exited (a durable channel's own
  exit code and stderr are the only signal; there is no queryable API).
- Dedup/coalescing/rate-limiting of repeated sends.
- Fan-out to multiple channels in a single `send` call.
- Backpressure or a size limit on a durable channel's own spool. An outage that never clears
  grows `<spoolDir>/<channel>/` without bound — this is a deliberate, honest limit, not an
  oversight: nixpush has no basis to decide a retention/eviction policy on the caller's
  behalf (the same reasoning [1] and [2] in `docs/rationale.md` already apply to retry policy
  in general). Monitor disk usage under `spoolDir` for a durable channel expected to see real
  traffic during a long-lived outage, the same way you would for any other on-disk queue.

Two things that used to be listed here as deferred are not deferred anymore — both are real,
both are opt-in per channel, and neither changes anything for a channel that doesn't ask for
it:

- **A crash-safe on-disk spool** (`channels.<name>.durable = true;` — see
  [Durable channels](#durable-channels-a-crash-safe-spool)). An outage on a durable channel's
  destination DELAYS delivery instead of dropping it, surviving both this CLI's own process
  exiting and a full host reboot. See
  [docs/rationale.md \[4\]](docs/rationale.md#4-an-opt-in-per-channel-spool-not-a-repo-wide-daemon)
  for why this could live here without the "thin core, one delivery attempt, no daemon" thesis
  above quietly becoming false for every consumer, not just the ones who opt in.
- **A channel-with-fallback** (`channels.<name>.fallback = "other";` — see
  [Channel fallback](#channel-fallback-unseal-failure-vs-hard-rejection)). Degrades to the
  named channel on an unseal failure or a hard rejection — never on a transient blip, never
  chained past one hop. See
  [docs/rationale.md \[5\]](docs/rationale.md#5-fallback-triggers-on-unseal-failure-and-hard-rejection-only-never-on-transient)
  for why those two conditions specifically, and no others.

Both are proven at RUNTIME, not just at eval time, in `checks/behavior.nix` — see the
Repository layout table above.

## Related projects

nixpush is one of several small, independently-usable open-source projects sharing a common
design system: **nixram** (memory-pressure tuning), **nixarch** (declarative Arch/CachyOS
workstations), and **nixnet** (declarative multi-uplink networking), among others. nixpush's
own niche is purely notification dispatch — usable alongside any of them, or standalone.

## License

MIT.
