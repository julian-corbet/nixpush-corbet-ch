# lib/nixpush.sh
#
# POSIX-sh helper for scripts that want a one-line function call instead
# of remembering `nixpush send`'s flags. Not installed anywhere
# automatically -- copy it alongside a script, or `. `/path/to/nixpush.sh``
# it, same as any other vendored shell helper. Requires only that
# `nixpush` itself is on PATH.
#
# Usage:
#   . /path/to/nixpush.sh
#   nixpush_send alerts "disk usage above threshold on $(hostname)"
#   nixpush_send alerts "backup failed" "nightly-backup" "urgent"
#
# Exit status is exactly `nixpush send`'s: 0 delivered, 3 permanently
# rejected, 2 usage/config error, anything else transient -- see
# CONTRIBUTING.md and README.md "CLI reference".

# nixpush_send <channel> <message> [title] [priority]
nixpush_send() {
    _nixpush_channel="$1"
    _nixpush_message="$2"
    _nixpush_title="${3:-}"
    _nixpush_priority="${4:-}"

    set -- nixpush send --channel "$_nixpush_channel"
    [ -n "$_nixpush_title" ] && set -- "$@" --title "$_nixpush_title"
    [ -n "$_nixpush_priority" ] && set -- "$@" --priority "$_nixpush_priority"
    set -- "$@" "$_nixpush_message"

    unset _nixpush_channel _nixpush_message _nixpush_title _nixpush_priority

    "$@"
}
