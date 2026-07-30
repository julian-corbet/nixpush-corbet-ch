# pkgs/nixpush.nix
#
# The nixpush core CLI: `send` / `channels` / `doctor` / `flush`. No daemon, no persistent
# process anywhere -- `flush` is a plain, one-shot invocation too, meant to be run
# periodically (by modules/default.nix's own `nixpush-flush` systemd timer, only ever
# rendered once at least one channel sets `durable = true`; see that file's header), never a
# long-running process of its own. Reads /etc/nixpush/channels.json fresh on every
# invocation, exactly as before durable channels or fallback existed. See CONTRIBUTING.md for
# the provider contract this execs against -- UNCHANGED by either feature below: a provider
# still sees exactly one exec, one JSON envelope on stdin, one exit code out, whether it was
# invoked from `send`'s inline path or from a spooled `flush` run. README.md "CLI reference"
# has the user-facing usage.
#
# `deliver_once` is the ONE place that ever execs a provider -- both `cmd_send`'s inline path
# (a non-durable channel) and `cmd_flush`'s per-message drain (a durable channel's spool)
# call it. For a channel with `durable = false` and `fallback = null` -- nixpush's ORIGINAL
# shape, and still every channel's default -- `deliver_once` is byte-for-byte the same
# provider-exec, exit-code classification, and `--json` emission `cmd_send` always did
# inline; see its own comment below for exactly where that "unchanged when off" contract is
# upheld. checks/behavior.nix proves this at runtime, not just by inspection.
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

           nixpush flush [--channel NAME] [--json]

    Exit codes for `send` mirror the provider contract exactly:
      0  delivered -- or, on a `durable` channel, durably QUEUED for later delivery
      3  permanently rejected -- do not blindly retry
      2  usage / configuration error (bad flags, unknown channel, ...)
      *  anything else: transient/unknown failure -- safe to retry

    `flush` drains every `durable` channel's on-disk spool (or just the one named by
    --channel), oldest-enqueued-first, attempting real delivery for each entry. A
    permanently-rejected entry is moved aside into <channel>/poison/ and does not block the
    rest of that channel's queue; a transient failure stops that channel's drain exactly
    where it is (order is preserved) and is retried on the next flush. Exits 0 only if every
    attempted channel's queue was left fully drained this run; nonzero if anything was
    poisoned, or left queued after a transient failure.

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
    durable_of()           { jq -r --arg n "$1" '.channels[$n].durable' "$channels_file"; }
    fallback_of()          { jq -r --arg n "$1" '.channels[$n].fallback // empty' "$channels_file"; }

    # resolve_spool_dir -- NIXPUSH_SPOOL_DIR overrides for testing (checks/behavior.nix runs
    # entirely inside a build sandbox with no real /var/lib), otherwise the value nixpush.nix
    # rendered into channels.json ("spoolDir"), otherwise the same default the module itself
    # falls back to.
    resolve_spool_dir() {
      if [ -n "''${NIXPUSH_SPOOL_DIR:-}" ]; then
        printf '%s' "$NIXPUSH_SPOOL_DIR"
      else
        jq -r '.spoolDir // "/var/lib/nixpush/spool"' "$channels_file"
      fi
    }

    # enqueue <channel> <envelope-json> <timeout>
    #
    # Atomically appends one spooled send under <spoolDir>/<channel>/ -- write to a hidden
    # tmpfile in the SAME directory, then `mv` (an atomic rename on the same filesystem) into
    # its final, public name, so a crash mid-write can never leave `cmd_flush` tripping over
    # a half-written entry. The final filename is a 20-digit zero-padded epoch-nanosecond
    # timestamp, then this process's pid, then a random suffix -- fixed-width and
    # all-digits, so a plain lexicographic `sort` is exactly enqueue order, which is what
    # `cmd_flush`'s oldest-first drain relies on; the pid+random suffix only exists to break
    # a tie between two sends landing in the same nanosecond.
    enqueue() {
      local channel="$1" envelope="$2" timeout="$3"
      local spool_dir; spool_dir=$(resolve_spool_dir)
      local dir="$spool_dir/$channel"
      mkdir -p "$dir" || die 2 "cannot create spool directory for channel \"$channel\": $dir"

      local ts; ts=$(date +%s%N)
      local fname; fname=$(printf '%020d-%d-%04d.json' "$ts" "$$" "$RANDOM")
      local tmp="$dir/.enqueuing-$fname"

      if ! jq -n --arg channel "$channel" --argjson envelope "$envelope" \
             --arg timeout "$timeout" --arg enqueuedAt "$ts" \
             '{channel: $channel, envelope: $envelope, timeout: ($timeout | tonumber), enqueuedAt: ($enqueuedAt | tonumber)}' \
             > "$tmp"
      then
        rm -f "$tmp"
        die 2 "failed to write spool entry for channel \"$channel\""
      fi

      mv "$tmp" "$dir/$fname" || { rm -f "$tmp"; die 2 "failed to enqueue spool entry for channel \"$channel\""; }
    }

    # `deliver_once` (defined below, right after this function -- deliberately AFTER, not
    # before: shellcheck's SC2030/SC2031 subshell-export tracking is purely textual, and
    # placing deliver_once's own env-var export ahead of this function's OWN read of
    # NIXPUSH_TIMEOUT_SECONDS as a default -- two sites that are causally unrelated, since
    # this read always happens before deliver_once is ever called -- was enough to make it
    # flag both as a false positive) is the ONE place a provider is ever exec'd.
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

      local default_priority default_tags
      default_priority=$(default_priority_of "$name")
      default_tags=$(default_tags_of "$name")

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

      local durable; durable=$(durable_of "$name")
      if [ "$durable" = "true" ]; then
        enqueue "$name" "$envelope" "$timeout"
        local code=$?
        if [ "$json_output" = true ]; then
          jq -nc --arg status "queued" --arg channel "$name" '{status: $status, channel: $channel}'
        fi
        exit "$code"
      fi

      deliver_once "$name" "$envelope" "$timeout" "$json_output" true
      exit $?
    }

    # deliver_once <name> <envelope-json> <timeout> <json_output:true|false> <allow_fallback:true|false> [<orig-channel>] [<orig-reason>]
    #
    # The ONE place that ever execs a provider -- directly, or via one recursive fallback
    # hop (never more than one: the recursive call always passes allow_fallback=false, so a
    # fallback channel's OWN `fallback`, if it even sets one, is never chased). Called by
    # cmd_send (channel just resolved from --channel/defaultChannel, allow_fallback=true) and
    # by cmd_flush (channel read back out of one spool entry, allow_fallback=true) -- invokes
    # a provider from inside a `$( ... )` command-substitution subshell so that a channel's
    # secretFile (sourced with `set -a` right before the provider runs) and
    # NIXPUSH_PROVIDER_SETTINGS/NIXPUSH_TIMEOUT_SECONDS exist ONLY for that one exec's
    # lifetime and are gone the instant the subshell exits, never leaking into this process's
    # own environment -- deliberate, not an oversight, see docs/rationale.md [3].
    #
    # UNCHANGED-WHEN-OFF CONTRACT: for a channel with no `fallback` configured, every branch
    # below that can fail reproduces cmd_send's ORIGINAL, pre-fallback behavior byte-for-byte
    # -- the same two `die 2` messages, the same provider-exec subshell, the same exit-code
    # classification, the same --json emission. The two `fb`-gated blocks are the ONLY places
    # this function's behavior can diverge from that original shape, and they are inert
    # whenever `fallback` is unset (fb is empty) or `allow_fallback` is false.
    deliver_once() {
      local name="$1" envelope="$2" timeout="$3" json_output="$4" allow_fallback="$5"
      local orig_channel="''${6:-}" orig_reason="''${7:-}"

      local provider provider_exe settings secret_file
      provider=$(provider_of "$name")
      provider_exe=$(provider_exe_of "$name")
      settings=$(settings_of "$name")
      secret_file=$(secret_file_of "$name")

      if [ "$provider_exe" = "null" ] || [ -z "$provider_exe" ]; then
        die 2 "channel \"$name\" uses provider \"$provider\", which did not resolve to an executable -- run: nixpush doctor"
      fi

      if [ -n "$secret_file" ] && [ "$secret_file" != "null" ] && [ ! -r "$secret_file" ]; then
        local fb=""
        if [ "$allow_fallback" = true ]; then
          fb=$(fallback_of "$name")
          [ "$fb" != "null" ] || fb=""
        fi
        if [ -n "$fb" ]; then
          echo "nixpush: channel \"$name\": secretFile not readable ($secret_file) -- unseal failure, falling back to channel \"$fb\"" >&2
          deliver_once "$fb" "$envelope" "$timeout" "$json_output" false "$name" "unseal"
          return $?
        fi
        die 2 "secretFile for channel \"$name\" is not readable: $secret_file"
      fi

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
        # shellcheck disable=SC2030,SC2031 # scoped to this subshell on purpose -- see docs/rationale.md [3]
        export NIXPUSH_PROVIDER_SETTINGS="$settings"
        export NIXPUSH_TIMEOUT_SECONDS="$timeout"
        printf '%s' "$envelope" | "$provider_exe" "''${provider_args[@]}"
      )
      code=$?
      set -e

      if [ "$code" -eq 3 ] && [ "$allow_fallback" = true ]; then
        local fb; fb=$(fallback_of "$name")
        if [ -n "$fb" ] && [ "$fb" != "null" ]; then
          echo "nixpush: channel \"$name\": permanently rejected -- hard error, falling back to channel \"$fb\"" >&2
          deliver_once "$fb" "$envelope" "$timeout" "$json_output" false "$name" "reject"
          return $?
        fi
      fi

      local status
      case "$code" in
        0) status=delivered ;;
        3) status=rejected ;;
        *) status=error ;;
      esac

      if [ "$json_output" = true ]; then
        local obj
        if [ -n "$raw_out" ] && jq -e . >/dev/null 2>&1 <<<"$raw_out"; then
          # Provider supports --json (recommended, not required) --
          # relay its object verbatim, plus what only core knows.
          obj=$(jq -c --arg channel "$name" --arg provider "$provider" \
            '. + {channel: $channel, provider: $provider}' <<<"$raw_out")
        else
          # Provider doesn't support --json (any provider is allowed to
          # skip it per CONTRIBUTING.md) -- degrade to what core itself
          # knows, no http_status.
          obj=$(jq -nc --arg status "$status" --arg channel "$name" --arg provider "$provider" \
            '{status: $status, channel: $channel, provider: $provider}')
        fi
        if [ -n "$orig_channel" ]; then
          obj=$(jq -c --arg f "$orig_channel" --arg r "$orig_reason" \
            '. + {fallbackFrom: $f, fallbackReason: $r}' <<<"$obj")
        fi
        printf '%s\n' "$obj"
      fi

      return "$code"
    }

    cmd_channels() {
      require_channels_file
      case "''${1:-}" in
        --names-only) jq -r '.channels | keys[]' "$channels_file"; return ;;
        "") : ;;
        *) die 2 "unknown flag: $1 (see: nixpush channels --names-only)" ;;
      esac
      jq -r '.channels | to_entries[] | "\(.key)\t\(.value.provider)\t\(.value.durable)\t\(.value.fallback // "")"' "$channels_file" \
        | while IFS=$'\t' read -r name provider durable fallback; do
            local annot=""
            [ "$durable" = "true" ] && annot="''${annot:+$annot, }durable"
            [ -n "$fallback" ] && annot="''${annot:+$annot, }fallback: $fallback"
            if [ -n "$annot" ]; then
              printf '%-8s -> %s (%s)\n' "$name" "$provider" "$annot"
            else
              printf '%-8s -> %s\n' "$name" "$provider"
            fi
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

        local fb; fb=$(fallback_of "$name")
        local fb_suffix=""
        if [ -n "$fb" ] && [ "$fb" != "null" ]; then
          fb_suffix=" (fallback: $fb)"
        fi

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
            printf '%-8s ok%s\n' "$name:" "$fb_suffix"
          else
            printf '%-8s FAILED%s\n' "$name:" "$fb_suffix"
            [ -n "$check_out" ] && printf '         %s\n' "$check_out"
            overall=1
          fi
        else
          printf '%-8s FAILED (%s)%s\n' "$name:" "$reason" "$fb_suffix"
          overall=1
        fi
      done

      exit "$overall"
    }

    # cmd_flush [--channel NAME] [--json]
    #
    # Drains every `durable` channel's on-disk spool (or just the one named by --channel),
    # oldest-enqueued-first (spool filenames sort lexicographically = chronologically -- see
    # `enqueue`'s own comment). A permanently-rejected entry (deliver_once returns 3) is
    # moved aside into <channel>/poison/ and does NOT stop the rest of that channel's queue --
    # this is the poison-message handling that keeps one bad message from wedging everything
    # behind it. A transient failure (deliver_once returns anything else) stops THIS
    # channel's drain exactly where it is, leaving every remaining entry -- including the one
    # that just failed -- still spooled in order, to be retried by the next flush (in
    # practice, the next `nixpush-flush.timer` tick). Different channels are independent: a
    # transient failure in one never blocks another channel's own drain in the same run.
    #
    # `die` calls inside `deliver_once` (an unresolvable provider, or an unreadable
    # secretFile with no fallback configured) are genuine configuration errors, not a
    # delivery classification -- they propagate all the way out and end this `flush`
    # invocation immediately, exactly as they would end a `send`. `nixpush doctor` is the
    # tool for catching that class of mistake before it ever reaches a scheduled flush; see
    # CONTRIBUTING.md's own recommendation to wire it into `ExecStartPre=`/CI.
    cmd_flush() {
      local channel_opt="" json_output=false
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --channel) need_arg --channel "$#"; channel_opt="$2"; shift 2 ;;
          --json)    json_output=true; shift ;;
          -h|--help) usage; exit 0 ;;
          *)         die 2 "unknown argument: $1 (see: nixpush flush --help)" ;;
        esac
      done

      require_channels_file
      local spool_dir; spool_dir=$(resolve_spool_dir)

      local names=()
      if [ -n "$channel_opt" ]; then
        jq -e --arg n "$channel_opt" '.channels[$n]' "$channels_file" >/dev/null 2>&1 \
          || die 2 "unknown channel \"$channel_opt\" (see: nixpush channels)"
        local is_durable; is_durable=$(durable_of "$channel_opt")
        [ "$is_durable" = "true" ] \
          || die 2 "channel \"$channel_opt\" is not durable (see: nixpush.channels.$channel_opt.durable) -- nothing to flush"
        names=("$channel_opt")
      else
        while IFS= read -r n; do names+=("$n"); done \
          < <(jq -r '.channels | to_entries[] | select(.value.durable == true) | .key' "$channels_file")
      fi

      local overall=0
      for name in "''${names[@]}"; do
        local dir="$spool_dir/$name"
        [ -d "$dir" ] || continue

        local files=()
        while IFS= read -r f; do files+=("$f"); done \
          < <(find "$dir" -maxdepth 1 -type f -name '[0-9]*.json' 2>/dev/null | LC_ALL=C sort)

        local total="''${#files[@]}" idx=0
        for f in "''${files[@]}"; do
          idx=$((idx + 1))
          local entry channel envelope entry_timeout
          entry=$(cat "$f") || { overall=1; continue; }
          channel=$(jq -r '.channel' <<<"$entry")
          envelope=$(jq -c '.envelope' <<<"$entry")
          entry_timeout=$(jq -r '.timeout' <<<"$entry")

          local code=0
          deliver_once "$channel" "$envelope" "$entry_timeout" "$json_output" true || code=$?

          case "$code" in
            0)
              rm -f "$f"
              ;;
            3)
              mkdir -p "$dir/poison"
              mv "$f" "$dir/poison/$(basename "$f")"
              echo "nixpush flush: channel \"$name\": message $idx/$total permanently rejected -- moved to poison, queue continues" >&2
              overall=1
              ;;
            *)
              echo "nixpush flush: channel \"$name\": message $idx/$total hit a transient failure -- stopping this channel's flush here, will retry from here next run" >&2
              overall=1
              break
              ;;
          esac
        done
      done

      exit "$overall"
    }

    [ "$#" -ge 1 ] || { usage; exit 2; }
    cmd="$1"; shift
    case "$cmd" in
      send)      cmd_send "$@" ;;
      channels)  cmd_channels "$@" ;;
      doctor)    cmd_doctor "$@" ;;
      flush)     cmd_flush "$@" ;;
      -h|--help) usage; exit 0 ;;
      *)         echo "nixpush: unknown command: $cmd" >&2; usage; exit 2 ;;
    esac
  '';
}
