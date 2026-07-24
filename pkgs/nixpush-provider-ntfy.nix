# pkgs/nixpush-provider-ntfy.nix
#
# The first-party ntfy provider: a real curl wrapper against ntfy's
# header-based publish API. One HTTP request per invocation, no internal
# retry loop -- see CONTRIBUTING.md for why that's the provider contract,
# not a shortcut taken here.
{ lib, writeShellApplication, curl, jq }:

writeShellApplication {
  name = "nixpush-provider-ntfy";
  runtimeInputs = [ curl jq ];
  text = ''
    # nixpush-provider-ntfy -- see CONTRIBUTING.md "Writing a nixpush
    # provider" for the full contract this implements.
    #
    #   nixpush-provider-ntfy                send (stdin: envelope JSON)
    #   nixpush-provider-ntfy --json         send, JSON status on stdout
    #   nixpush-provider-ntfy check-settings validate only, no network

    usage() {
      cat >&2 <<'EOF'
    usage: nixpush-provider-ntfy [--json]
           nixpush-provider-ntfy check-settings

    Not meant to be run by hand under normal use -- nixpush's core CLI
    execs this with NIXPUSH_PROVIDER_SETTINGS set and the envelope JSON
    on stdin. See CONTRIBUTING.md.
    EOF
    }

    json_mode=false
    subcommand="send"
    for arg in "$@"; do
      case "$arg" in
        --json) json_mode=true ;;
        check-settings) subcommand="check-settings" ;;
        -h|--help) usage; exit 0 ;;
        *)
          echo "nixpush-provider-ntfy: unrecognized argument: $arg" >&2
          usage
          exit 1
          ;;
      esac
    done

    settings="''${NIXPUSH_PROVIDER_SETTINGS:-}"
    if [ -z "$settings" ]; then
      echo "nixpush-provider-ntfy: NIXPUSH_PROVIDER_SETTINGS is not set" >&2
      exit 1
    fi
    if ! jq -e . >/dev/null 2>&1 <<<"$settings"; then
      echo "nixpush-provider-ntfy: NIXPUSH_PROVIDER_SETTINGS is not valid JSON" >&2
      exit 1
    fi

    server=$(jq -r '.serverUrl // empty' <<<"$settings")
    # NTFY_TOPIC (if set) wins over settings.topic -- mirrors NTFY_TOKEN exactly: both are
    # sourced from the channel's `secretFile` (never rendered into channels.json), which lets
    # a topic that IS the credential (ntfy's own "unguessable topic name as shared secret"
    # convention) stay out of the Nix store entirely. settings.topic remains the right choice
    # for a non-secret routing key -- both paths are supported, env wins when both are set.
    topic="''${NTFY_TOPIC:-$(jq -r '.topic // empty' <<<"$settings")}"

    # --- check-settings: validate shape only, no network call. ---------
    if [ "$subcommand" = "check-settings" ]; then
      reasons=()
      [ -z "$server" ] && reasons+=("settings.serverUrl is missing or empty")
      [ -z "$topic" ] && reasons+=("settings.topic is missing or empty")
      case "$server" in
        http://*|https://*) : ;;
        "") : ;; # already reported above
        *) reasons+=("settings.serverUrl '$server' does not start with http:// or https://") ;;
      esac
      if [ "''${#reasons[@]}" -gt 0 ]; then
        printf 'nixpush-provider-ntfy: %s\n' "''${reasons[@]}" >&2
        exit 1
      fi
      echo "nixpush-provider-ntfy: settings ok (server=$server, topic=$topic, topic_source=$([ -n "''${NTFY_TOPIC:-}" ] && echo env || echo settings), token=$([ -n "''${NTFY_TOKEN:-}" ] && echo set || echo unset))" >&2
      exit 0
    fi

    # --- send: one HTTP request, no retry. ------------------------------
    if [ -z "$server" ] || [ -z "$topic" ]; then
      echo "nixpush-provider-ntfy: settings.serverUrl and settings.topic are both required (run 'check-settings' for details)" >&2
      exit 3
    fi

    envelope=$(cat)
    if ! jq -e . >/dev/null 2>&1 <<<"$envelope"; then
      echo "nixpush-provider-ntfy: stdin envelope is not valid JSON" >&2
      exit 3
    fi

    body=$(jq -r '.message // empty' <<<"$envelope")
    if [ -z "$body" ]; then
      echo "nixpush-provider-ntfy: envelope has no .message (the only required field)" >&2
      exit 3
    fi

    args=(-s -o /dev/null -w '%{http_code}' --max-time "''${NIXPUSH_TIMEOUT_SECONDS:-15}")

    title=$(jq -r '.title // empty' <<<"$envelope"); [ -n "$title" ] && args+=(-H "Title: $title")
    prio=$(jq -r '.priority // empty' <<<"$envelope"); [ -n "$prio" ] && args+=(-H "Priority: $prio")
    tags=$(jq -r '.tags // [] | join(",")' <<<"$envelope"); [ -n "$tags" ] && args+=(-H "Tags: $tags")
    click=$(jq -r '.click // empty' <<<"$envelope"); [ -n "$click" ] && args+=(-H "Click: $click")
    attach=$(jq -r '.attach // empty' <<<"$envelope"); [ -n "$attach" ] && args+=(-H "Attach: $attach")
    delay=$(jq -r '.delay // empty' <<<"$envelope"); [ -n "$delay" ] && args+=(-H "Delay: $delay")
    # `actions` has no ntfy header equivalent this provider implements
    # yet -- degrade gracefully (drop it) rather than fail the send, per
    # the provider contract in CONTRIBUTING.md.
    [ -n "''${NTFY_TOKEN:-}" ] && args+=(-H "Authorization: Bearer $NTFY_TOKEN")

    # `|| true` -- without it, a curl-level failure that never got as
    # far as an HTTP response (DNS failure, connection refused, TLS
    # handshake failure, `--max-time` hit) exits this script immediately
    # via `set -e`'s command-substitution-assignment rule, with curl's
    # own raw exit code, BEFORE the classification below runs -- silent
    # (no status line), and skipping `--json` output entirely. curl's
    # `-w` already writes "000" to stdout in exactly this case (its own
    # convention for "no HTTP status was ever received", which the case
    # statement below already sorts into the transient-failure branch);
    # `|| true` only neutralizes curl's nonzero exit status so that
    # already-captured "000" survives to be classified, instead of
    # tacking on a second, redundant fallback value.
    code=$(curl "''${args[@]}" --data-binary "$body" "$server/$topic") || true
    code="''${code:-000}" # belt-and-suspenders: empty if curl wrote nothing at all

    status=""
    exit_code=1
    case "$code" in
      2??) status="delivered"; exit_code=0 ;;
      4??) status="rejected"; exit_code=3 ;;
      *)   status="error"; exit_code=1 ;;
    esac

    if [ "$json_mode" = true ]; then
      # `$((10#$code))` (forced base 10) rather than passing "$code"
      # straight to jq's --argjson: curl's own connection-failure
      # sentinel is the literal string "000", and JSON's number grammar
      # forbids leading zeros -- jq would reject it as invalid JSON.
      # Bash arithmetic strips them cleanly (and rejects anything that
      # isn't actually digits, which %{http_code} always is).
      http_status_num=$((10#$code))
      jq -nc --arg status "$status" --argjson http_status "$http_status_num" \
        '{status: $status, http_status: $http_status}'
    else
      case "$status" in
        delivered) echo "delivered (http $code)" >&2 ;;
        rejected)  echo "rejected (http $code)" >&2 ;;
        *)         echo "transient failure (http $code)" >&2 ;;
      esac
    fi

    exit "$exit_code"
  '';
}
