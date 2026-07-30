# FAQ

These entries exist because code comments in `modules/*.nix` and `pkgs/*.nix` point back to
them by name. If a comment says "see docs/faq.md", the matching heading is here.

## Why is there no daemon, and why is a channel's queue opt-in rather than the default?

See [`rationale.md` \[1\]](rationale.md#1-stateless-synchronous-cli-by-default-no-daemon-core).
Short version: nixpush's most common callers (health-check daemons, watchdog timers,
`OnFailure=` units that get another tick regardless) already own their own "did this alert get
through" state, because they already run on a schedule and already need to interpret "I didn't
hear back" at the application level. Defaulting every channel to a queue would duplicate a
guarantee most callers already have, for real added complexity paid on every send. But that
argument does NOT hold for a caller whose alert is a genuine one-off with no next tick to
retry from — see [`rationale.md` \[4\]](rationale.md#4-an-opt-in-per-channel-spool-not-a-repo-wide-daemon)
for why `channels.<name>.durable = true` exists for exactly that shape, and for why it still
doesn't turn nixpush into a daemon for anyone who never asks for it.

## Why does `nixpush send` only make one delivery attempt, with no internal retry?

Same reasoning as the daemon question, one level down: retry policy needs to know things only
the *caller* knows (is this alert still relevant to retry? how many times has this specific
event already retried? should retries back off?). A provider or the core CLI retrying
internally would be guessing at policy it has no context for. Wire retry into the caller
instead — systemd's own `Restart=on-failure` / `RestartSec=`, or a caller-side loop, both
compose cleanly with a CLI that has a stable, checkable exit code per attempt.

## Why three exit-code classes (`0`/`3`/other) instead of plain success/failure?

See [`rationale.md` \[2\]](rationale.md#2-three-exit-code-classes-not-two-not-five). Short
version: "should this be retried" is the one distinction that changes what a caller actually
does next, and plain success/failure throws exactly that away.

## Why `3` specifically for "permanently rejected"?

No deep numerological reason — it just needed to be a value outside `{0, 1, 2}`, since `1` is
bash's generic error convention (too likely to collide with "a provider crashed for a reason
that has nothing to do with the contract," which should read as transient/unknown, not
permanent) and `2` is reserved by the *core CLI itself* for usage/config errors that never even reached
a provider. `3` was free and is easy to remember as "3 like the leading digit of the HTTP 4xx
class it's derived from" once you know the mnemonic, but that's a memory aid, not the actual
reason.

## Can I write a provider in something other than bash?

Yes — see [`CONTRIBUTING.md`](../CONTRIBUTING.md). The contract is stdin JSON in, environment
variables read, one HTTP-style exit code out. Nothing about it is bash-specific; the
first-party ntfy provider happens to be a small `curl`+`jq` script because that's a completely
adequate amount of engineering for "make one HTTP request and check its status," not because
the contract requires shell.

## Why does `secretFile` exist instead of just putting tokens in `settings`?

`settings` is rendered verbatim into `/etc/nixpush/channels.json`, which is a real file on
disk (mode `0440`, but still a file, and still visible to `nix store diff-closures` /
build logs / anyone who can read `/etc`). `secretFile` is a path to something else entirely
— usually a sops-nix or agenix-rendered `KEY=VALUE` file with its own tighter permissions —
that the CLI sources fresh into the environment for one `send` invocation and never persists
anywhere nixpush controls. See
[`rationale.md` \[3\]](rationale.md#3-secretfile-is-sourced-fresh-per-invocation-never-baked-into-channelsjson)
for the full reasoning.

## Doesn't `nixpush flush` mean there's a daemon now?

No -- `flush` is a plain, one-shot CLI invocation, exactly the same shape `send` always was:
read `/etc/nixpush/channels.json` fresh, do some work, exit. Nothing about it stays resident
in memory between invocations, and nothing is shared across invocations except the plain files
sitting in `nixpush.spoolDir`. `modules/default.nix` wires a `Type = "oneshot"` systemd
service to a timer that calls `nixpush flush` periodically -- and only renders that
service/timer pair at all once at least one channel sets `durable = true`. A host that never
opts any channel into `durable` gets no spool directory, no flush service, no flush timer;
`nixpush send` on every one of its channels is byte-for-byte the same synchronous, one-attempt
codepath as before this existed. See
[`rationale.md` \[4\]](rationale.md#4-an-opt-in-per-channel-spool-not-a-repo-wide-daemon) for
the full "why this doesn't quietly break the 'no daemon' thesis" reasoning, and
`checks/assertions.nix`'s `checks/no-durable-channel-renders-no-flush-service-or-timer` for
where that claim is actually checked, not just asserted in prose.

## Why does `fallback` ignore transient failures?

Because a transient failure (a DNS hiccup, a timeout, a provider's own 5xx) is, by
definition, the one class of failure that might succeed on a plain retry against the SAME
destination -- see [`rationale.md` \[2\]](rationale.md#2-three-exit-code-classes-not-two-not-five)
for why the provider contract already classifies it separately from a hard `3` rejection.
Falling back on it too would mean one bad second on the primary provider silently re-routes
the alert to a completely different destination that was never actually broken -- worse than
doing nothing, since an operator checking the primary topic afterward would see nothing there
and have no idea the alert went out somewhere else. `fallback` triggers on exactly two
conditions instead: the primary's `secretFile` failed to unseal (the provider is never even
invoked), or the primary's provider genuinely ran and hard-rejected (exit `3`). Both are
durably true about the primary right now in a way a transient blip is not. See
[`rationale.md` \[5\]](rationale.md#5-fallback-triggers-on-unseal-failure-and-hard-rejection-only-never-on-transient)
for the full reasoning, and `checks/behavior.nix`'s own transient-failure scenario for where
this is proven to actually hold at runtime, in both directions (the two conditions that DO
trigger it, and the one that must not).

## Why does `nixpush doctor` sometimes report a channel FAILED when it's actually fine?

`check-settings` is an *optional* part of the provider contract (a provider `MAY` implement
it). If a provider doesn't, invoking it with the `check-settings` subcommand just hits that
provider's own "unrecognized argument" error path and exits nonzero — `doctor` has no way to
distinguish that from a genuine settings problem, so it reports FAILED either way. This is a
known, accepted edge of making `check-settings` opt-in rather than mandatory (mandating it
would raise the bar for a same-day community provider PR for a check most providers benefit
from anyway, but not all will bother implementing on day one).
