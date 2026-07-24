# FAQ

These entries exist because code comments in `modules/*.nix` and `pkgs/*.nix` point back to
them by name. If a comment says "see docs/faq.md", the matching heading is here.

## Why is there no daemon or persistent queue?

See [`rationale.md` \[1\]](rationale.md#1-stateless-synchronous-cli-no-daemon-no-queue-core-v1).
Short version: nixpush's actual callers (health-check daemons, watchdog timers, `OnFailure=`
units) already own their own "did this alert get through" state, because they already run on
a schedule and already need to interpret "I didn't hear back" at the application level. A
second, independent retry/backoff/spool state machine underneath that would duplicate a
guarantee the caller usually needs anyway, for real added complexity (atomic write/rename,
crash recovery, backpressure eviction). Deferred to a possible future `nixpush-daemon`
package, not discarded — see the README's
[Non-goals & future direction](../README.md#non-goals--future-direction).

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

## Why does `nixpush doctor` sometimes report a channel FAILED when it's actually fine?

`check-settings` is an *optional* part of the provider contract (a provider `MAY` implement
it). If a provider doesn't, invoking it with the `check-settings` subcommand just hits that
provider's own "unrecognized argument" error path and exits nonzero — `doctor` has no way to
distinguish that from a genuine settings problem, so it reports FAILED either way. This is a
known, accepted edge of making `check-settings` opt-in rather than mandatory (mandating it
would raise the bar for a same-day community provider PR for a check most providers benefit
from anyway, but not all will bother implementing on day one).
