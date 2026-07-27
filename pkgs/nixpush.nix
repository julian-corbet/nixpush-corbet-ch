# pkgs/nixpush.nix
#
# The nixpush core CLI: `send` / `channels` / `doctor`. No daemon, no
# persistent process state beyond the NixOS-rendered
# /etc/nixpush/channels.json this reads fresh on every invocation. See
# CONTRIBUTING.md for the provider contract this execs against, and
# README.md "CLI reference" for user-facing usage.
{ lib, writeShellApplication, jq }:

writeShellApplication {
  name = "nixpush";
  runtimeInputs = [ jq ];
  text = ''
    # nixpush -- see README.md "CLI reference" / CONTRIBUTING.md.

    channels_file="''${NIXPUSH_CHANNELS_FILE:-/etc/nixpush/channels.json}"

    die() {
      local code="$1"; shift
      echo "nixpush: $*" >&2
      exit "$code"
    }

    need_arg() {
      # $1 = flag name being parsed, $2 = remaining arg count ("$#" at
      # the point of the flag, before shifting) -- guards against
      # `set -u` aborting with bash's own "unbound variable" message on
      # a trailing flag with no value.
      [ "$2" -ge 2 ] || die 2 "$1 requires an argument"
    }

    usage() {
      cat >&2 <<'USAGE'
    usage: nixpush send [--channel NAME] [--title TITLE]
                         [--priority min|low|default|high|urgent]
                         [--tag TAG]... [--click URL] [--attach URL]
                         [--action LABEL=URL]... [--delay DURATION]
                         [--timeout SECONDS] [--json] MESSAGE

           nixpush channels [--names-only]

           nixpush doctor [--channel NAME]

    Exit codes for `send` mirror the provider contract exactly:
      0  delivered
      3  permanently rejected -- do not blindly retry
      2  usage / configuration error (bad flags, unknown channel, ...)
      *  anything else: transient/unknown failure -- safe to retry

    See CONTRIBUTING.md and README.md for the full reference.
    USAGE
    }

    require_channels_file() {
      if [ ! -r "$channels_file" ]; then
        die 2 "cannot read channels file: $channels_file (is nixpush.enable set in your NixOS configuration?)"
      fi
      jq -e . >/dev/null 2>&1 < "$channels_file" \
        || die 2 "channels file is not valid JSON: $channels_file"
    }

    resolve_channel_name() {
      local requested="$1" name
      if [ -n "$requested" ]; then
        name="$requested"
      else
        name=$(jq -r '.defaultChannel // empty' "$channels_file")
        [ -n "$name" ] || die 2 "no --channel given and nixpush.defaultChannel is unset"
      fi
      jq -e --arg n "$name" '.channels[$n]' "$channels_file" >/dev/null 2>&1 \
        || die 2 "unknown channel \"$name\" (see: nixpush channels)"
      printf '%s' "$name"
    }

    provider_of()         { jq -r --arg n "$1" '.channels[$n].provider' "$channels_file"; }
    provider_exe_of()     { jq -r --arg n "$1" '.channels[$n].providerExe' "$channels_file"; }
    settings_of()         { jq -c --arg n "$1" '.channels[$n].settings' "$channels_file"; }
    secret_file_of()      { jq -r --arg n "$1" '.channels[$n].secretFile // empty' "$channels_file"; }
    default_priority_of() { jq -r --arg n "$1" '.channels[$n].defaultPriority' "$channels_file"; }
    default_tags_of()     { jq -c --arg n "$1" '.channels[$n].defaultTags' "$channels_file"; }

    # Both cmd_send and cmd_doctor invoke the provider from inside a
    # `$( ... )` command-substitution subshell so that a channel's
    # secretFile -- sourced with `set -a` right before the provider
    # runs -- and NIXPUSH_PROVIDER_SETTINGS/NIXPUSH_TIMEOUT_SECONDS
    # exist ONLY for that one exec's lifetime and are gone the instant
    # the subshell exits, never leaking into this process's own
    # environment. That's deliberate, not an oversight -- see
    # docs/rationale.md [3] -- hence the SC2030/SC2031 suppressions
    # below: shellcheck can't tell "scoped on purpose" from "exported
    # by mistake."
    cmd_send() {
      local channel_opt="" title="" priority="" click="" attach="" delay="" timeout=""
      local json_output=false
      local tags=() actions=()

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --channel)  need_arg --channel "$#";  channel_opt="$2"; shift 2 ;;
          --title)    need_arg --title "$#";    title="$2";       shift 2 ;;
          --priority) need_arg --priority "$#"; priority="$2";    shift 2 ;;
          --tag)      need_arg --tag "$#";      tags+=("$2");     shift 2 ;;
          --click)    need_arg --click "$#";    click="$2";       shift 2 ;;
          --attach)   need_arg --attach "$#";   attach="$2";      shift 2 ;;
          --action)   need_arg --action "$#";   actions+=("$2");  shift 2 ;;
          --delay)    need_arg --delay "$#";    delay="$2";       shift 2 ;;
          --timeout)  need_arg --timeout "$#";  timeout="$2";     shift 2 ;;
          --json)     json_output=true; shift ;;
          -h|--help)  usage; exit 0 ;;
          --)         shift; break ;;
          -*)         die 2 "unknown flag: $1 (see: nixpush send --help)" ;;
          *)          break ;;
        esac
      done

      [ "$#" -ge 1 ] || die 2 "MESSAGE is required (see: nixpush send --help)"
      local message="$1"; shift
      [ "$#" -eq 0 ] || die 2 "unexpected extra argument(s): $*"

      case "$priority" in
        ""|min|low|default|high|urgent) : ;;
        *) die 2 "invalid --priority: $priority (must be one of: min low default high urgent)" ;;
      esac

      require_channels_file
      local name; name=$(resolve_channel_name "$channel_opt")

      local provider provider_exe settings secret_file default_priority default_tags
      provider=$(provider_of "$name")
      provider_exe=$(provider_exe_of "$name")
      settings=$(settings_of "$name")
      secret_file=$(secret_file_of "$name")
      default_priority=$(default_priority_of "$name")
      default_tags=$(default_tags_of "$name")

      if [ "$provider_exe" = "null" ] || [ -z "$provider_exe" ]; then
        die 2 "channel \"$name\" uses provider \"$provider\", which did not resolve to an executable -- run: nixpush doctor"
      fi
      if [ -n "$secret_file" ] && [ "$secret_file" != "null" ] && [ ! -r "$secret_file" ]; then
        die 2 "secretFile for channel \"$name\" is not readable: $secret_file"
      fi

      [ -n "$priority" ] || priority="$default_priority"
      if [ "''${#tags[@]}" -eq 0 ]; then
        while IFS= read -r t; do
          [ -n "$t" ] && tags+=("$t")
        done < <(jq -r '.[]?' <<<"$default_tags")
      fi

      local tags_json="[]"
      if [ "''${#tags[@]}" -gt 0 ]; then
        tags_json=$(printf '%s\n' "''${tags[@]}" | jq -R . | jq -s .)
      fi
      local actions_json="[]"
      if [ "''${#actions[@]}" -gt 0 ]; then
        # LABEL=URL -- split on the FIRST "=" only, so a URL containing
        # its own "=" (a query string) survives intact.
        actions_json=$(printf '%s\n' "''${actions[@]}" \
          | jq -R 'split("=") | {label: .[0], url: (.[1:] | join("="))}' | jq -s .)
      fi

      local envelope
      envelope=$(jq -n \
        --arg message "$message" \
        --arg title "$title" \
        --arg priority "$priority" \
        --argjson tags "$tags_json" \
        --arg click "$click" \
        --arg attach "$attach" \
        --argjson actions "$actions_json" \
        --arg delay "$delay" \
        '{message: $message}
         + (if $title != "" then {title: $title} else {} end)
         + (if $priority != "" then {priority: $priority} else {} end)
         + (if ($tags | length) > 0 then {tags: $tags} else {} end)
         + (if $click != "" then {click: $click} else {} end)
         + (if $attach != "" then {attach: $attach} else {} end)
         + (if ($actions | length) > 0 then {actions: $actions} else {} end)
         + (if $delay != "" then {delay: $delay} else {} end)')

      [ -n "$timeout" ] || timeout="''${NIXPUSH_TIMEOUT_SECONDS:-15}"

      local provider_args=()
      [ "$json_output" = true ] && provider_args+=(--json)

      local raw_out="" code=0
      set +e
      raw_out=$(
        set -a
        if [ -n "$secret_file" ] && [ "$secret_file" != "null" ]; then
          # shellcheck disable=SC1090
          . "$secret_file"
        fi
        set +a
        # shellcheck disable=SC2030,SC2031 # scoped to this subshell on purpose -- see the file-level comment above cmd_send
        export NIXPUSH_PROVIDER_SETTINGS="$settings"
        export NIXPUSH_TIMEOUT_SECONDS="$timeout"
        printf '%s' "$envelope" | "$provider_exe" "''${provider_args[@]}"
      )
      code=$?
      set -e

      local status
      case "$code" in
        0) status=delivered ;;
        3) status=rejected ;;
        *) status=error ;;
      esac

      if [ "$json_output" = true ]; then
        if [ -n "$raw_out" ] && jq -e . >/dev/null 2>&1 <<<"$raw_out"; then
          # Provider supports --json (recommended, not required) --
          # relay its object verbatim, plus what only core knows.
          jq -c --arg channel "$name" --arg provider "$provider" \
            '. + {channel: $channel, provider: $provider}' <<<"$raw_out"
        else
          # Provider doesn't support --json (any provider is allowed to
          # skip it per CONTRIBUTING.md) -- degrade to what core itself
          # knows, no http_status.
          jq -nc --arg status "$status" --arg channel "$name" --arg provider "$provider" \
            '{status: $status, channel: $channel, provider: $provider}'
        fi
      fi

      exit "$code"
    }

    cmd_channels() {
      require_channels_file
      case "''${1:-}" in
        --names-only) jq -r '.channels | keys[]' "$channels_file"; return ;;
        "") : ;;
        *) die 2 "unknown flag: $1 (see: nixpush channels --names-only)" ;;
      esac
      jq -r '.channels | to_entries[] | "\(.key)\t\(.value.provider)"' "$channels_file" \
        | while IFS=$'\t' read -r name provider; do
            printf '%-8s -> %s\n' "$name" "$provider"
          done
    }

    cmd_doctor() {
      local channel_opt=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --channel) need_arg --channel "$#"; channel_opt="$2"; shift 2 ;;
          -h|--help) usage; exit 0 ;;
          *) die 2 "unknown argument: $1 (see: nixpush doctor --help)" ;;
        esac
      done

      require_channels_file

      local names=()
      if [ -n "$channel_opt" ]; then
        jq -e --arg n "$channel_opt" '.channels[$n]' "$channels_file" >/dev/null 2>&1 \
          || die 2 "unknown channel \"$channel_opt\" (see: nixpush channels)"
        names=("$channel_opt")
      else
        while IFS= read -r n; do names+=("$n"); done \
          < <(jq -r '.channels | keys[]' "$channels_file")
      fi

      local overall=0
      for name in "''${names[@]}"; do
        local provider_exe settings secret_file ok=true reason=""
        provider_exe=$(provider_exe_of "$name")
        settings=$(settings_of "$name")
        secret_file=$(secret_file_of "$name")

        if [ "$provider_exe" = "null" ] || [ -z "$provider_exe" ]; then
          ok=false
          reason="provider not resolvable (misconfigured nixpush.providers)"
        elif [ -n "$secret_file" ] && [ "$secret_file" != "null" ] && [ ! -r "$secret_file" ]; then
          ok=false
          reason="secretFile not readable: $secret_file"
        fi

        if [ "$ok" = true ]; then
          local check_out=""
          # Note: `check-settings` is OPTIONAL in the provider contract
          # (CONTRIBUTING.md) -- a provider that doesn't implement it
          # will exit nonzero on this unrecognized subcommand, and this
          # channel is reported FAILED even though it may in fact be
          # fine. This is an accepted, documented sharp edge of an
          # opt-in contract step, not a bug: authors who want `doctor`
          # coverage implement `check-settings`.
          if check_out=$(
            set -a
            if [ -n "$secret_file" ] && [ "$secret_file" != "null" ]; then
              # shellcheck disable=SC1090
              . "$secret_file"
            fi
            set +a
            # shellcheck disable=SC2030,SC2031 # scoped to this subshell on purpose -- see the file-level comment above cmd_send
            export NIXPUSH_PROVIDER_SETTINGS="$settings"
            "$provider_exe" check-settings 2>&1
          ); then
            printf '%-8s ok\n' "$name:"
          else
            printf '%-8s FAILED\n' "$name:"
            [ -n "$check_out" ] && printf '         %s\n' "$check_out"
            overall=1
          fi
        else
          printf '%-8s FAILED (%s)\n' "$name:" "$reason"
          overall=1
        fi
      done

      exit "$overall"
    }

    [ "$#" -ge 1 ] || { usage; exit 2; }
    cmd="$1"; shift
    case "$cmd" in
      send)      cmd_send "$@" ;;
      channels)  cmd_channels "$@" ;;
      doctor)    cmd_doctor "$@" ;;
      -h|--help) usage; exit 0 ;;
      *)         echo "nixpush: unknown command: $cmd" >&2; usage; exit 2 ;;
    esac
  '';
}
