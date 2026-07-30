# checks/behavior.nix
#
# BUILD-LEVEL proof, entirely inside the Nix build sandbox: the real `nixpush` CLI (built
# from pkgs/nixpush.nix, unmodified), run against a hand-written channels.json and a handful
# of fully-controlled fake providers -- never a real network call, never a real host. This is
# the one place either of nixpush's two opt-in guarantees can actually be SEEN working,
# rather than merely inspected:
#
#   * a durable channel's spool surviving what stands in for "the CLI's own process died, or
#     the whole host rebooted, mid-outage" -- concretely, a brand-new `nixpush flush`
#     invocation is itself a fresh process with no in-memory state carried over from any
#     previous one (there is nothing else FOR nixpush to carry over -- it re-reads
#     channels.json and re-lists the spool directory from scratch every single invocation),
#     so two independent `flush` calls separated by "the destination is still down" and then
#     "the destination just recovered" already exercise exactly the same code path a real
#     crash-and-restart would;
#   * oldest-enqueued-first delivery order;
#   * a permanently-rejected message getting poisoned instead of wedging the channel behind
#     it;
#   * a channel's fallback firing on exactly its two documented trigger conditions (secretFile
#     unreadable, provider hard-rejects) and never on a third (a transient failure), followed
#     exactly one hop and never chained;
#   * the ORIGINAL synchronous, one-attempt, 0/3/other codepath being byte-for-byte unchanged
#     for a channel that sets neither `durable` nor `fallback` -- proven by simply re-running
#     nixpush's pre-existing, documented exit-code/--json contract and asserting it still
#     holds.
#
# Calls `pkgs.callPackage ../pkgs/nixpush.nix { }` DIRECTLY -- not through a NixOS
# eval-config -- the same "build and run the real artifact standalone" shape nixwatch's own
# checks/behavior.nix uses for its generated scripts, for the identical reason: a full NixOS
# toplevel eval buys nothing extra here, `nixpush` is already a plain, standalone package.
{ pkgs, lib, system }:

let
  nixpushPkg = pkgs.callPackage ../pkgs/nixpush.nix { };
  nixpushCmd = "${nixpushPkg}/bin/nixpush";

  # A fake provider is fully described by its own exit behavior -- every one of them logs the
  # envelope's `.message` to $FAKE_LOG first, unconditionally, so this proof can assert BOTH
  # "was this provider invoked at all" (did $FAKE_LOG grow) and "in what order, with what
  # content" (grep the accumulated lines), never just the final exit code.
  mkFakeProvider = { name, exitSnippet }:
    pkgs.writeShellScriptBin name ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail
      envelope=$(cat)
      msg=$(${pkgs.jq}/bin/jq -r '.message' <<<"$envelope")
      printf '%s\n' "$msg" >> "''${FAKE_LOG:?FAKE_LOG not set}"
      ${exitSnippet}
    '';

  fakeOk = mkFakeProvider { name = "fake-ok"; exitSnippet = "exit 0"; };
  fakeReject = mkFakeProvider { name = "fake-reject"; exitSnippet = "exit 3"; };
  fakeTransient = mkFakeProvider { name = "fake-transient"; exitSnippet = "exit 1"; };

  # Rejects (3) only a message containing the substring POISON, succeeds (0) otherwise --
  # proves ONE bad message in an otherwise-healthy queue gets poisoned, not the whole channel.
  fakePoisonAware = mkFakeProvider {
    name = "fake-poison-aware";
    exitSnippet = ''
      case "$msg" in
        *POISON*) exit 3 ;;
        *) exit 0 ;;
      esac
    '';
  };

  # Transient-fails (1) until $FAKE_MARKER exists, then succeeds (0) -- stands in for "the
  # destination recovers between one flush tick and the next" without needing two different
  # provider binaries.
  fakeRecovers = mkFakeProvider {
    name = "fake-recovers";
    exitSnippet = ''
      if [ -e "''${FAKE_MARKER:?FAKE_MARKER not set}" ]; then
        exit 0
      else
        exit 1
      fi
    '';
  };

  mkChannel =
    { providerExe
    , secretFile ? null
    , durable ? false
    , fallback ? null
    }: {
      provider = "fake";
      inherit providerExe secretFile durable fallback;
      settings = { };
      defaultPriority = "default";
      defaultTags = [ ];
    };

  channelsJson = pkgs.writeText "nixpush-behavior-channels.json" (builtins.toJSON {
    defaultChannel = null;
    # Deliberately a path that could never be created inside the sandbox -- every scenario
    # below overrides it via $NIXPUSH_SPOOL_DIR instead, proving that override path works
    # too (the same one a real host never needs, but this proof does).
    spoolDir = "/nixpush-behavior-proof-should-never-touch-this";
    channels = {
      # ── off path: neither durable nor fallback set -- must be byte-for-byte unchanged ────
      plain = mkChannel { providerExe = "${fakeOk}/bin/fake-ok"; };
      plain-reject = mkChannel { providerExe = "${fakeReject}/bin/fake-reject"; };
      plain-transient = mkChannel { providerExe = "${fakeTransient}/bin/fake-transient"; };

      # ── durable spool ──────────────────────────────────────────────────────────────────
      queue-basic = mkChannel { providerExe = "${fakeOk}/bin/fake-ok"; durable = true; };
      queue-order = mkChannel { providerExe = "${fakeRecovers}/bin/fake-recovers"; durable = true; };
      queue-poison = mkChannel { providerExe = "${fakePoisonAware}/bin/fake-poison-aware"; durable = true; };

      # ── fallback: unseal failure (secretFile configured but unreadable) ────────────────
      page-unseal = mkChannel {
        providerExe = "${fakeOk}/bin/fake-ok"; # must NEVER actually be invoked
        secretFile = "/nonexistent/nixpush-behavior-proof-secret-1.env";
        fallback = "noise-unseal";
      };
      noise-unseal = mkChannel { providerExe = "${fakeOk}/bin/fake-ok"; };

      # ── fallback: hard rejection (provider genuinely runs, exits 3) ────────────────────
      page-hard-reject = mkChannel { providerExe = "${fakeReject}/bin/fake-reject"; fallback = "noise-hard-reject"; };
      noise-hard-reject = mkChannel { providerExe = "${fakeOk}/bin/fake-ok"; };

      # ── fallback must NEVER fire on a merely transient failure ─────────────────────────
      page-transient-nofallback = mkChannel { providerExe = "${fakeTransient}/bin/fake-transient"; fallback = "noise-should-never-fire"; };
      noise-should-never-fire = mkChannel { providerExe = "${fakeOk}/bin/fake-ok"; };

      # ── fallback is opt-in: same unseal failure, no fallback configured -> unchanged ────
      page-unseal-no-fallback = mkChannel {
        providerExe = "${fakeOk}/bin/fake-ok";
        secretFile = "/nonexistent/nixpush-behavior-proof-secret-2.env";
      };

      # ── fallback is followed exactly ONE hop, never chained ────────────────────────────
      chain-a = mkChannel { providerExe = "${fakeReject}/bin/fake-reject"; fallback = "chain-b"; };
      chain-b = mkChannel { providerExe = "${fakeReject}/bin/fake-reject"; fallback = "chain-c"; };
      chain-c = mkChannel { providerExe = "${fakeOk}/bin/fake-ok"; };
    };
  });
in
pkgs.runCommand "nixpush-behavior-proof"
{
  nativeBuildInputs = [ pkgs.coreutils pkgs.bash pkgs.jq pkgs.gnugrep pkgs.findutils ];
}
  ''
    set -euo pipefail
    export NIXPUSH_CHANNELS_FILE=${channelsJson}
    export FAKE_LOG="$PWD/fake.log"
    : > "$FAKE_LOG"
    export NIXPUSH_SPOOL_DIR="$PWD/spool"

    fail() { echo "FAIL: $*"; exit 1; }
    logcount() { wc -l < "$FAKE_LOG"; }
    lastlines() { tail -n "$1" "$FAKE_LOG"; }

    # ═══ 1. off path: durable=false, fallback=null -- byte-for-byte unchanged behavior ═══
    ${nixpushCmd} send --channel plain "hello" \
      || fail "the plain channel (no durable, no fallback) must deliver successfully"
    [ "$(logcount)" -eq 1 ] || fail "expected exactly one delivery attempt for the plain channel, got $(logcount)"
    lastlines 1 | grep -qx "hello" || fail "expected the plain channel's provider to receive the message verbatim"

    code=0
    ${nixpushCmd} send --channel plain-reject "nope" >/dev/null 2>&1 || code=$?
    [ "$code" -eq 3 ] || fail "a permanently-rejecting provider with no fallback must exit 3 (unchanged provider-contract exit code), got $code"

    code=0
    ${nixpushCmd} send --channel plain-transient "blip" >/dev/null 2>&1 || code=$?
    { [ "$code" -ne 0 ] && [ "$code" -ne 3 ]; } || fail "a transient provider failure must exit neither 0 nor 3 (unchanged), got $code"

    # NOTE: named `json_resp`, deliberately NOT `out` -- runCommand's own $out (the
    # derivation's output path) lives in the same shell scope as this script, and shadowing
    # it with a same-named local variable silently redirects the final `touch $out` into a
    # bogus file instead of the real output (caught while writing this proof, not
    # theoretical).
    json_resp=$(${nixpushCmd} send --channel plain --json "json-check")
    printf '%s' "$json_resp" | jq -e '.status == "delivered" and .channel == "plain" and .provider == "fake"' >/dev/null \
      || fail "unchanged --json shape expected for the plain channel, got: $json_resp"

    echo "off path (durable=false, fallback=null): byte-for-byte unchanged PASSED"

    # ═══ 2. durable channel: send enqueues and returns fast, nothing delivered until flush ═══
    : > "$FAKE_LOG"
    ${nixpushCmd} send --channel queue-basic "q1" \
      || fail "enqueueing to a durable channel must succeed (exit 0) even though nothing has been delivered yet"
    [ "$(logcount)" -eq 0 ] || fail "a durable channel's send must NEVER invoke the provider inline, got $(logcount) invocation(s)"
    entries=$(find "$NIXPUSH_SPOOL_DIR/queue-basic" -maxdepth 1 -type f -name '[0-9]*.json' | wc -l)
    [ "$entries" -eq 1 ] || fail "expected exactly one spooled entry after one send, found $entries"

    ${nixpushCmd} flush --channel queue-basic || fail "flush of a healthy durable channel must succeed"
    [ "$(logcount)" -eq 1 ] || fail "flush must actually deliver the spooled message"
    entries=$(find "$NIXPUSH_SPOOL_DIR/queue-basic" -maxdepth 1 -type f -name '[0-9]*.json' 2>/dev/null | wc -l)
    [ "$entries" -eq 0 ] || fail "a delivered spool entry must be removed, found $entries left"

    echo "durable channel: enqueue-then-flush PASSED"

    # ═══ 3. oldest-first ordering + an outage DELAYS delivery, never DROPS it, and survives
    #        independent CLI invocations (the process-restart / host-reboot equivalent, since
    #        nixpush keeps no in-memory state between invocations at all) ═══
    : > "$FAKE_LOG"
    rm -rf "$NIXPUSH_SPOOL_DIR/queue-order" "$PWD/queue-order.marker"
    export FAKE_MARKER="$PWD/queue-order.marker"

    ${nixpushCmd} send --channel queue-order "order-1"
    ${nixpushCmd} send --channel queue-order "order-2"
    ${nixpushCmd} send --channel queue-order "order-3"
    entries=$(find "$NIXPUSH_SPOOL_DIR/queue-order" -maxdepth 1 -type f -name '[0-9]*.json' | wc -l)
    [ "$entries" -eq 3 ] || fail "expected all three sends to enqueue while the destination is down, found $entries"

    # A brand-new `flush` invocation IS a brand-new, independent process -- there is no
    # shared in-memory state anywhere in nixpush to lose across it, so this alone already
    # stands in for both a crashed-CLI restart and a rebooted host. The destination is
    # STILL down (marker absent).
    code=0
    ${nixpushCmd} flush --channel queue-order || code=$?
    [ "$code" -ne 0 ] || fail "flush must report a nonzero exit while a transient failure is still blocking the channel"
    [ "$(logcount)" -eq 1 ] || fail "flush must attempt exactly the OLDEST message, then stop -- got $(logcount) attempt(s)"
    lastlines 1 | grep -qx "order-1" || fail "the oldest enqueued message must be attempted first, got: $(lastlines 1)"
    entries=$(find "$NIXPUSH_SPOOL_DIR/queue-order" -maxdepth 1 -type f -name '[0-9]*.json' | wc -l)
    [ "$entries" -eq 3 ] || fail "a transient failure must leave every not-yet-delivered message spooled, found $entries left"

    # The outage clears; the NEXT flush (in reality, the next nixpush-flush.timer tick) --
    # again a fresh, independent invocation -- drains the rest, still oldest-first, and
    # nothing was ever dropped despite the delay.
    touch "$FAKE_MARKER"
    ${nixpushCmd} flush --channel queue-order || fail "flush must succeed once the destination recovers"
    [ "$(logcount)" -eq 4 ] || fail "expected the remaining two messages delivered (4 attempts total across both flushes), got $(logcount)"
    tail -n 3 "$FAKE_LOG" | tr '\n' ' ' | grep -qF "order-1 order-2 order-3" \
      || fail "expected order-1, order-2, order-3 delivered in exactly that (oldest-first) order, got: $(tail -n 3 "$FAKE_LOG" | tr '\n' ' ')"
    entries=$(find "$NIXPUSH_SPOOL_DIR/queue-order" -maxdepth 1 -type f -name '[0-9]*.json' 2>/dev/null | wc -l)
    [ "$entries" -eq 0 ] || fail "queue-order must be fully drained once the outage clears, found $entries left"

    echo "spool: oldest-first delivery + outage delays without dropping + survives independent flush invocations PASSED"

    # ═══ 4. poison-message handling: one hard-rejected message must not wedge the queue ═══
    : > "$FAKE_LOG"
    rm -rf "$NIXPUSH_SPOOL_DIR/queue-poison"
    ${nixpushCmd} send --channel queue-poison "good-1"
    ${nixpushCmd} send --channel queue-poison "this is a POISON message"
    ${nixpushCmd} send --channel queue-poison "good-2"

    code=0
    ${nixpushCmd} flush --channel queue-poison || code=$?
    [ "$code" -ne 0 ] || fail "flush must report nonzero when a message was poisoned, for operator visibility"
    [ "$(logcount)" -eq 3 ] || fail "expected all three messages ATTEMPTED (the poison one included) -- got $(logcount)"
    tail -n 3 "$FAKE_LOG" | tr '\n' '|' | grep -qF "good-1|this is a POISON message|good-2|" \
      || fail "expected good-1, the poison message, then good-2 attempted in that order, got: $(tail -n 3 "$FAKE_LOG")"

    active=$(find "$NIXPUSH_SPOOL_DIR/queue-poison" -maxdepth 1 -type f -name '[0-9]*.json' 2>/dev/null | wc -l)
    [ "$active" -eq 0 ] || fail "queue-poison must be fully drained (good-1 delivered, poison moved aside, good-2 delivered), found $active still active"
    poisoned=$(find "$NIXPUSH_SPOOL_DIR/queue-poison/poison" -maxdepth 1 -type f -name '[0-9]*.json' 2>/dev/null | wc -l)
    [ "$poisoned" -eq 1 ] || fail "expected exactly one message moved to the poison subdirectory, found $poisoned"
    grep -q POISON "$NIXPUSH_SPOOL_DIR/queue-poison/poison/"*.json \
      || fail "expected the poisoned entry's own envelope to be preserved on disk for inspection"

    echo "poison-message handling: one hard-rejected message never wedges its queue PASSED"

    # ═══ 5. fallback -- unseal failure: the primary's provider must NEVER be invoked ═══
    : > "$FAKE_LOG"
    ${nixpushCmd} send --channel page-unseal "unseal-test" \
      || fail "a channel whose secret failed to unseal, with a working fallback, must still report overall success"
    [ "$(logcount)" -eq 1 ] || fail "expected exactly ONE provider invocation (the fallback's) -- got $(logcount), meaning the primary's provider ran despite its secret failing to unseal"
    lastlines 1 | grep -qx "unseal-test" || fail "expected the fallback provider to receive the message verbatim"

    json_resp=$(${nixpushCmd} send --channel page-unseal --json "unseal-json-test")
    printf '%s' "$json_resp" | jq -e '.status == "delivered" and .channel == "noise-unseal" and .fallbackFrom == "page-unseal" and .fallbackReason == "unseal"' >/dev/null \
      || fail "expected --json provenance (fallbackFrom/fallbackReason) for an unseal-triggered fallback, got: $json_resp"

    echo "fallback: unseal failure degrades to the fallback channel WITHOUT ever invoking the primary's provider PASSED"

    # ═══ 6. fallback -- hard error: the primary's provider IS invoked, and rejects, first ═══
    : > "$FAKE_LOG"
    ${nixpushCmd} send --channel page-hard-reject "hard-error-test" \
      || fail "a hard-rejected primary with a working fallback must still report overall success"
    [ "$(logcount)" -eq 2 ] || fail "expected TWO provider invocations (the primary's real rejection, then the fallback's) -- got $(logcount)"
    lastlines 2 | tr '\n' ' ' | grep -qF "hard-error-test hard-error-test" \
      || fail "expected the SAME message logged once by the rejecting primary and once by the fallback, got: $(lastlines 2)"

    echo "fallback: a hard-rejecting primary degrades to the fallback, after genuinely being attempted PASSED"

    # ═══ 7. fallback must NEVER trigger on a merely transient failure ═══
    : > "$FAKE_LOG"
    code=0
    ${nixpushCmd} send --channel page-transient-nofallback "transient-test" >/dev/null 2>&1 || code=$?
    { [ "$code" -ne 0 ] && [ "$code" -ne 3 ]; } || fail "a transient primary failure must be relayed as-is (neither 0 nor 3), got $code"
    [ "$(logcount)" -eq 1 ] || fail "a transient failure must NEVER engage the fallback -- expected exactly one (the primary's own) invocation, got $(logcount)"
    lastlines 1 | grep -qx "transient-test" || fail "expected only the primary's own provider to have been invoked"

    echo "fallback: a transient primary failure is never treated as a fallback trigger PASSED"

    # ═══ 8. fallback is opt-in: an unseal failure with NO fallback configured is unchanged ═══
    code=0
    ${nixpushCmd} send --channel page-unseal-no-fallback "no-fallback-test" >/dev/null 2>&1 || code=$?
    [ "$code" -eq 2 ] || fail "an unreadable secretFile with no fallback configured must still exit 2 (unchanged), got $code"

    echo "fallback opt-in: an unreadable secretFile with no fallback configured is unchanged (exit 2) PASSED"

    # ═══ 9. fallback is followed exactly ONE hop -- a fallback channel's OWN fallback is
    #        never chased, even when it also hard-rejects ═══
    : > "$FAKE_LOG"
    code=0
    ${nixpushCmd} send --channel chain-a "chain-test" >/dev/null 2>&1 || code=$?
    [ "$code" -eq 3 ] || fail "a fallback channel that ALSO hard-rejects must surface as rejected (3), never chase its own fallback further, got $code"
    [ "$(logcount)" -eq 2 ] || fail "expected exactly two provider invocations (chain-a, then chain-b) and chain-c NEVER invoked, got $(logcount)"

    echo "fallback: followed exactly one hop, never chained PASSED"

    touch $out
  ''
