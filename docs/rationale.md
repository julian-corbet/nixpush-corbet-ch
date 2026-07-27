# Rationale

Numbered design decisions, referenced by number from code comments and from the README.
Each entry states the decision, the alternative it was weighed against, and why the
alternative lost — not just the outcome.

## [1] Stateless synchronous CLI, no daemon, no queue (core v1)

**Decision:** `nixpush send` performs exactly one delivery attempt and returns. There is no
daemon and no durable spool in core.

**Alternative considered:** an always-on daemon with a durable local spool, atomic enqueue,
and its own retry/backoff/dead-lettering — "enqueue must succeed even when the network is
down."

**Why the alternative lost:** that argument is real, but it's solving a problem that, for
nixpush's actual primary caller shape, already has an owner. Callers that fire alerts on
infrastructure failure (health-check daemons, watchdog timers, `OnFailure=` units) are
exactly the kind of caller that already runs on a recurring schedule and already needs to
keep its *own* state about what it's alerting on and when it last succeeded. Bolting a
second, independent queue-with-retry-and-backoff state machine underneath that, inside
nixpush itself, means two systems trying to own the same "did this get through yet" question
— more surface area (atomic write/rename discipline, crash-recovery sweeps, backpressure
eviction, clock-skew-sensitive backoff timers) for a guarantee the caller was often going to
need to provide anyway to correctly interpret "no daemon queue" health at the application
level.

The daemon+spool idea isn't discarded, just deferred — see the README's
[Non-goals & future direction](../README.md#non-goals--future-direction). If a future caller
genuinely needs delivery to survive *its own* process dying mid-alert (not just a network
blip), that's a `nixpush-daemon` package layered on top of the same provider contract, with
zero changes required to core or to existing providers.

## [2] Three exit-code classes, not two, not five

**Decision:** a provider (and `nixpush send` itself) exits exactly `0` (delivered), `3`
(permanently rejected — don't retry), or anything else (transient — safe to retry). `2` is
additionally reserved by the *core CLI itself* (not the provider contract) for usage/config
errors — an unknown channel, a bad flag, an unreadable `secretFile` — which are neither a
delivery success nor a provider-classified failure at all.

**Alternative considered:** plain `0`/nonzero, matching a shell script's usual convention;
or a richer set mirroring HTTP status codes more granularly (e.g. distinct codes for auth
failure vs. bad payload vs. rate-limited).

**Why three wins:** two classes throw away exactly the distinction that matters most to a
caller deciding whether to retry — a caller that can't tell "the topic doesn't exist" from
"the network blipped" ends up either retrying pointlessly forever or giving up on transient
failures it should have retried. That's the one bit of information worth forcing every
provider to classify. More than three classes pushes complexity onto every provider author
for a distinction most callers won't act on differently anyway (a caller almost never
branches differently on "bad payload" vs. "rate-limited" vs. "auth failure" — all three are
"stop, a human needs to look at this," i.e. `3`). Mirrors the same three-way split shell
scripts already reach for informally when checking curl's `%{http_code}` against `2xx`/`4xx`/
other — nixpush just makes that convention a documented contract instead of everyone
reinventing it slightly differently.

## [3] `secretFile` is sourced fresh per invocation, never baked into `channels.json`

**Decision:** `nixpush.channels.<name>.secretFile` is recorded as a *path* in
`/etc/nixpush/channels.json`, never dereferenced by Nix. The core CLI reads the file at
`send` time, sources it into a subshell that only lives for the duration of that one exec,
and the values never appear in `channels.json`, never get copied into the Nix store, and
never sit in a long-lived process's memory.

**Alternative considered:** resolve the secret at Nix eval/build time and either (a) render
it directly into `channels.json` (world- or group-readable on disk, in the Nix store's build
log, in `nix store diff-closures` output — a real information leak for very little gain), or
(b) require every provider to independently know how to read a sops-nix/agenix path itself
(pushes the same plumbing into every provider, community and first-party alike).

**Why sourcing at invocation time wins:** it keeps secrets out of the Nix store and out of
any process's memory for longer than one `send` call needs them, without requiring a
provider to understand *how* secrets are managed on a given host at all — sops-nix, agenix,
a hand-rolled `install -m 0600`, whatever renders a plain `KEY=VALUE` file works identically,
because the provider only ever sees an already-set environment variable. This is exactly the
same shape most systemd units already use for `EnvironmentFile=`; nixpush's core CLI is
effectively doing that sourcing step itself instead of delegating it to systemd, since a
provider is a one-shot subprocess, not a unit of its own.
