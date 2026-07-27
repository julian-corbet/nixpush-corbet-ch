# Contributing to nixpush

nixpush is built to grow a provider ecosystem it doesn't have to maintain itself.
Contributions — first-party fixes, and especially community providers — are welcome under
the project's [MIT](LICENSE) license.

## Ground rules

- **FOSS-clean core.** This repo carries no real ntfy topic name, real server URL, real
  hostname, or any other site-specific fact — not even in a comment or a test fixture. Every
  example uses an obviously-fake placeholder (`REPLACE_ME_...`, `example.org`,
  `example-host`). Real values belong only in whatever private configuration imports this
  flake.
- **The provider contract is the whole seam.** A PR that adds features by growing the
  `stdin` JSON / environment-variable / exit-code contract below affects every existing
  provider, first- and third-party alike. Prefer growing it additively (a new optional
  envelope field a provider may ignore) over anything that changes existing field meanings.
- **No retry loops inside a provider.** See [Non-goals](README.md#non-goals--future-direction)
  in the README for why — this is a hard rule, not a style preference, and PRs adding one
  will be asked to remove it.
- **Commit style.** Imperative subject line, a body that says *why* when the *why* isn't
  obvious from the diff. No AI attribution lines.

## Writing a nixpush provider

A provider is a Nix package exposing exactly one executable, `nixpush-provider-<name>`,
registered with:

```nix
nixpush.providers.<name> = pkgs.<pkg>;
```

(First-party providers additionally ship a NixOS module — e.g. `nixpush.ntfy.enable`
— that does this registration for you and layers on provider-specific top-level options. A
community provider doesn't need one; registering the package directly is enough.)

Per `send`, the core CLI execs the provider once, synchronously, and waits for it to exit.

### stdin

One JSON object, the normalized notification envelope:

```json
{
  "title":    "string, optional",
  "message":  "string, required -- the only required field",
  "priority": "min | low | default | high | urgent, optional",
  "tags":     ["string", "..."],
  "click":    "url, optional -- opened on tap/click",
  "attach":   "url, optional -- attachment to include",
  "actions":  [{ "label": "string", "url": "string" }],
  "delay":    "duration string, e.g. \"30m\", optional -- deferred delivery"
}
```

Every field except `message` is optional and **must** degrade gracefully if your backend
doesn't support it — silently drop `actions` rather than error, for example. Do not fail a
send just because the caller supplied a field your backend can't express.

### environment

| Variable                     | Always set? | Meaning |
|-------------------------------|-------------|---------|
| `NIXPUSH_PROVIDER_SETTINGS`   | yes         | JSON-serialized copy of the channel's `settings` attrs (e.g. `{"serverUrl":"...","topic":"..."}`). Shape is provider-defined and opaque to core. |
| *(secretFile contents)*       | only if the channel (or provider) sets `secretFile`/`tokenFile` | `KEY=VALUE` lines sourced into the environment for this invocation only — e.g. `NTFY_TOKEN=...`. Absent/unset if no secret file is configured. Providers needing no auth simply ignore this. |
| `NIXPUSH_TIMEOUT_SECONDS`     | yes (has a default) | Caller-configured timeout. The provider **must** itself honor this for its network call (e.g. `curl --max-time "$NIXPUSH_TIMEOUT_SECONDS"`) and treat its own timeout as a transient failure, not a hang. |

### exit code

Exactly one of three classes:

| Code | Meaning | Core's action |
|---|---|---|
| `0` | Delivery confirmed (backend returned success, e.g. HTTP 2xx) | Reports `delivered`. |
| `3` | Permanently rejected — do not retry (backend 4xx-class: bad topic, malformed payload, auth failure) | Reports `rejected`. Caller should not blindly retry. |
| anything else | Transient / unknown failure — safe to retry | Reports `error`. Caller decides whether/when to retry. |

### requirements

- **MUST NOT** print secrets (tokens, full topic URLs if considered sensitive) to stdout or
  stderr.
- **MUST** make exactly **one** delivery attempt — no internal retry loop. Retry policy
  belongs to the caller (systemd `Restart=`, `OnFailure=`, or a caller-side loop), by design
  — see the [Design decision](README.md#design-decision-why-the-stateless-shape-wins-for-v1)
  in the README.
- **MAY** print one human-readable status line to stderr, for logging.
- **MAY** support a second subcommand, `check-settings`, that reads
  `NIXPUSH_PROVIDER_SETTINGS` (and any secret env) from the environment, validates
  shape/required keys with **no network call**, and exits `0`/`1` with a reason on stderr.
  Used by `nixpush doctor` and recommended as an `ExecStartPre=`/CI check so a misconfigured
  channel fails at deploy time, not at alert time. A provider that skips this simply won't get
  useful `nixpush doctor` coverage — `doctor` will report that channel FAILED (the
  unrecognized-subcommand exit code, not a real settings problem); that's an accepted, known
  edge of an opt-in contract step.
- **MAY** support its own `--json` flag mirroring the core CLI, emitting
  `{"status":"delivered"|"rejected"|"error","http_status":<int>}` to stdout instead of
  relying on exit-code-only. Core relays this object verbatim (adding `channel` and
  `provider` keys) in its own `--json` output; a provider that skips `--json` still gets a
  best-effort `{"status":...,"channel":...,"provider":...}` object from core, just without
  `http_status`.

### Reference implementation

[`pkgs/nixpush-provider-ntfy.nix`](pkgs/nixpush-provider-ntfy.nix) is a real, working provider
against ntfy's header-based publish API, using this exact 0/3/other split derived from curl's
returned HTTP status class. It implements every `MAY`, too (`check-settings` and `--json`), so
it doubles as a template for a new provider — start by copying its shape and swapping the
`curl` call for your backend's own HTTP (or other transport) call.

It's also the reference example of a provider accepting a *secret-sourced* non-token setting:
`NTFY_TOPIC`, if present in the environment (i.e. sourced from the channel's `secretFile`,
same as `NTFY_TOKEN`), wins over `settings.topic` from `NIXPUSH_PROVIDER_SETTINGS`. Any
provider whose backend uses an unguessable-value-as-credential (not just bearer tokens) can
follow this same pattern — prefer an env var, fall back to the settings JSON — to let a
consumer choose per-channel whether that value is a non-secret routing key or something that
must stay out of the Nix store.

A provider can be written in any language that can read stdin, read environment variables,
make a network call with a timeout, and set an exit code — nothing here is bash-specific,
that's just what the first-party provider happens to use.

## Before you open a PR

1. `nix flake check` — evaluates both NixOS modules and builds both packages.
2. If you're touching `pkgs/nixpush.nix` or `pkgs/nixpush-provider-ntfy.nix`: run
   `shellcheck` over the rendered script (`nix build .#nixpush && shellcheck result/bin/nixpush`,
   similarly for the provider) — `writeShellApplication` already runs this at build time, so a
   green `nix build` already implies a green shellcheck, but running it directly gives faster
   iteration.
3. A new community provider PR against *this* repo is generally out of scope — nixpush's own
   repo ships core + the first-party ntfy provider only, by design (see the provider registry
   note in `modules/default.nix`). Community providers live in their own repos and register
   into `nixpush.providers` from the consumer's flake; open an issue here to get
   listed in README.md's provider list once yours exists and works.

## Reporting issues

Regular GitHub issues are fine for everything here — nixpush has no secrets-handling code of
its own beyond "source this file into an environment for one process lifetime and never write
it anywhere," so there's no private-disclosure process beyond what your provider's own backend
already needs.
