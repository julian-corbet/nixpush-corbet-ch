# Rationale

Numbered design decisions, referenced by number from code comments and from the README.
Each entry states the decision, the alternative it was weighed against, and why the
alternative lost — not just the outcome.

## [1] Stateless synchronous CLI by default, no daemon (core)

**Decision:** `nixpush send` performs exactly one delivery attempt and returns, for every
channel, unless that specific channel opts into `durable = true`. There is no daemon anywhere
in nixpush — durability, where a channel asks for it, is a plain one-shot `nixpush flush`
invocation on a systemd timer, never a resident process; see [4] below for exactly how that
stays true.

**Alternative considered:** an always-on daemon with a durable local spool, atomic enqueue,
and its own retry/backoff/dead-lettering for EVERY channel, unconditionally — "enqueue must
succeed even when the network is down."

**Why the alternative lost, as the DEFAULT:** for nixpush's most common caller shape —
health-check daemons, watchdog timers, anything that already runs on a recurring schedule —
that argument is solving a problem that already has an owner. Such a caller already needs to
keep its *own* state about what it's alerting on and when it last succeeded; a still-failing
probe gets another chance to alert on its very next tick regardless of whether THIS alert's
`send` made it through. Bolting a second, independent queue-with-retry-and-backoff state
machine underneath every send, for every channel, means two systems trying to own the same
"did this get through yet" question for a caller shape that mostly didn't need it.

**Why it is not the ONLY shape nixpush supports, unlike v1's original framing:** that
argument stops holding for a caller whose alert is itself a one-off with no next tick to
retry from — `OnFailure=` on a unit that only ever fails once, a script's own `trap ERR`, a
one-shot migration's failure path. For that shape, a network blip during the ten seconds the
alerting process was alive really does mean the alert is gone forever, with nothing anywhere
positioned to notice and re-fire it. `channels.<name>.durable = true` (see [4]) is exactly
this repo's answer for that caller shape — added later than v1, once a real consumer
(nixwatch's own generalization of a private `fleet-watchdog.nix`) hit it, not spelled out here
originally. The decision above still holds as the DEFAULT for every channel that doesn't ask
otherwise; it was never a claim that no caller would ever need more.

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

## [4] An opt-in, per-channel spool -- not a repo-wide daemon

**Decision:** `nixpush.channels.<name>.durable = true;` gives exactly that one channel a
crash-safe, on-disk spool: `nixpush send` enqueues instead of delivering inline, and a
`nixpush flush` invocation -- itself a plain, one-shot CLI call, never a long-running process
-- drains it. `modules/default.nix` renders the `nixpush-flush` systemd service+timer pair
that calls `flush` periodically ONLY when at least one channel actually sets `durable = true`;
a host with zero durable channels gets neither unit at all. A channel that leaves `durable`
at its default (`false`) gets the exact same synchronous, one-attempt codepath nixpush has
always had -- see `pkgs/nixpush.nix`'s `deliver_once` for exactly where that "unchanged when
off" contract is upheld in the code itself, and `checks/behavior.nix` for the runtime proof.

**Alternative considered:** reject the feature outright, on the grounds that [1] above already
explains why v1 shipped with no daemon and no queue at all -- "the caller already owns this
kind of state, don't duplicate it."

**Why the alternative lost, for THIS specific case:** [1]'s argument holds for a caller that
already runs on a recurring schedule and can reasonably re-interpret "did this get through" at
its own next tick (a health-check daemon retrying its OWN probe). It does not hold for a
caller whose alert is itself a one-off, fired once from a place that will not be re-checked --
`OnFailure=` on a unit that only fails once, a script's own `trap ERR`, a one-shot migration's
failure path. For that shape of caller, "the network blipped for the ten seconds this alert's
own process was alive" really does mean the alert is gone forever under nixpush v1, with
nothing anywhere positioned to notice and re-fire it. A caller-side retry loop cannot fix this
either, because IT is the thing that already finished (successfully or not) by the time the
network blip is over -- there is no "next tick" to retry from. The queue has to live somewhere
between "the alert was raised" and "the bytes left the box," and for exactly this caller
shape, nothing else in the system is positioned to own that gap.

**Why this does not quietly turn nixpush into a daemon for everyone:** the load-bearing
design choice is that `flush` is not a new KIND of process -- it is the SAME "one shell
invocation, reads config fresh, execs a provider once per message, exits" shape `send` always
was, just invoked once per spool entry instead of once per CLI call, and driven by a
`Type = "oneshot"` systemd timer (the same shape nixwatch already uses for each of its own
per-check ticks) rather than a `Type = "simple"` unit that stays resident. Nothing is ever
resident in memory between flushes; nothing is shared across invocations except the plain
files sitting in `spoolDir`. A consumer who never sets `durable = true` on any channel gets
precisely nixpush v1's behavior, in full, including "no daemon anywhere in the composed
system" -- checked concretely in `checks/assertions.nix`'s
`checks/no-durable-channel-renders-no-flush-service-or-timer`.

**Poison handling, and why a transient failure behaves differently:** a permanently-rejected
entry (provider exit `3`) will never succeed no matter how many more times `flush` retries it
-- leaving it in place would wedge every message enqueued after it forever, since drain order
is oldest-first. Moving it to `<channel>/poison/` is the one thing that keeps the queue live
without inventing a retry-count/backoff policy nixpush has no basis to choose on the caller's
behalf (the exact kind of policy [1] and [2] both already argue belongs to the caller, not
core). A transient failure gets the opposite treatment on purpose: it might well succeed next
time, so `flush` stops that channel's drain exactly where it is (preserving oldest-first order
for the next attempt) rather than skipping ahead -- skipping ahead would silently reorder
delivery the first time a destination has one bad minute.

## [5] Fallback triggers on unseal failure and hard rejection only, never on transient

**Decision:** `nixpush.channels.<name>.fallback = "other";` degrades to `other` on exactly two
conditions -- this channel's `secretFile` is configured but unreadable at send time ("failed
to unseal"), or its provider returns `3` (permanently rejected, genuinely attempted first).
Anything transient (any other nonzero exit) is relayed to the caller completely unchanged;
fallback never engages. Followed exactly one hop -- the fallback channel's own `fallback`, if
it sets one, is never chased.

**Alternative considered:** fall back on ANY failure, transient included -- "the paging topic
is unreachable, deliver the page some other way, whatever the reason."

**Why the alternative lost:** a transient failure (a DNS hiccup, a `--max-time` timeout, a
5xx from the push provider's own infrastructure) is, by construction, the ONE class of failure
that might succeed on a plain retry against the SAME destination -- that is the entire reason
the provider contract classifies it separately from `3` in the first place (see [2] above).
Falling back on it too would mean a single bad second on the primary provider silently
re-routes traffic to a DIFFERENT destination that was never actually broken, which is worse
than doing nothing: an operator who later checks the primary "paging" topic and sees nothing
there has no idea their alert actually went out somewhere else, under some other name, with no
record connecting the two beyond a `fallbackFrom`/`fallbackReason` field an operator has to
already know to go looking for. Restricting the trigger to unseal-failure and hard-rejection
keeps the semantics legible: BOTH of those are genuinely, durably wrong about the primary
channel right now (a secret that isn't there isn't going to appear mid-retry; a provider that
just said "no" isn't going to say "yes" to the identical request a second later), which is
exactly the situation a human configured a fallback destination to survive.

**Why unseal failure and hard rejection get DIFFERENT internal treatment, despite both
triggering the same fallback:** an unseal failure is caught BEFORE any provider is ever
invoked -- there is no way to make an HTTP request (or whatever a given provider's transport
is) with a credential that was never read, so nixpush does not try, and the primary's
provider process never runs at all for that send. A hard rejection can only be discovered BY
actually running the provider and reading its exit code back. `checks/behavior.nix` proves
both shapes concretely: the unseal scenario shows exactly one provider invocation total (the
fallback's), the hard-rejection scenario shows exactly two (the primary's real, genuine
rejection, then the fallback's) -- the difference is directly observable, not just asserted.

**Why exactly one hop, never a chain:** a fallback-of-a-fallback immediately raises "what if
they point at each other" -- solvable (cycle detection, a hop-count limit), but for a feature
whose entire point is "degrade ONE step to the plain, boring, always-on channel," a chain
buys nothing a single hop doesn't already provide in the overwhelming common case (page ->
noise), while adding a whole class of configuration mistake (a cycle) that then needs its own
assertion, its own error message, and its own test coverage. The self-reference and
unknown-channel assertions in `modules/default.nix` are the entire validation surface this
needs; a real multi-hop requirement, if one ever appears, is exactly the kind of thing worth
opening as its own dated entry in `experiments/`, not something to speculatively build now.
