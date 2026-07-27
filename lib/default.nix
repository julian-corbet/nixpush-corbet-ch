# lib/default.nix
#
# Nix-level helper surface for wiring nixpush sends into OTHER modules'
# units, without those modules needing to remember `nixpush send`'s flag
# syntax. Intentionally thin -- "shell out to the binary" stays the real
# integration seam; this only saves callers from hand-assembling the
# command line. Exposed both as a flake output (`nixpush.lib`) and, for
# convenience, as `config.nixpush.lib` once the core module is
# imported (see modules/default.nix).
{ lib }:
{
  # mkSendCommand { channel = "alerts"; priority = "urgent"; } ->
  #   "nixpush send --channel 'alerts' --priority 'urgent' "
  #
  # A ready-to-embed shell command STRING with everything except the
  # trailing MESSAGE baked in -- append your own quoted message, e.g.:
  #
  #   systemd.services.example.serviceConfig.ExecStopPost =
  #     "${config.nixpush.lib.mkSendCommand { channel = "alerts"; priority = "urgent"; }} 'unit %n failed'";
  #
  # Every argument is shell-escaped via `lib.escapeShellArg`; nothing
  # here interpolates untrusted values unescaped.
  mkSendCommand =
    { channel
    , binary ? "nixpush"
    , title ? null
    , priority ? null
    , tags ? [ ]
    , click ? null
    , attach ? null
    , actions ? [ ] # [ { label = "..."; url = "..."; } ... ]
    , delay ? null
    , timeout ? null
    , json ? false
    }:
    let
      esc = lib.escapeShellArg;
      flag = name: value:
        lib.optionalString (value != null) "${name} ${esc (toString value)} ";
      tagFlags = lib.concatMapStrings (t: "--tag ${esc t} ") tags;
      actionFlags = lib.concatMapStrings
        (a: "--action ${esc "${a.label}=${a.url}"} ")
        actions;
    in
    "${esc binary} send --channel ${esc channel} "
    + flag "--title" title
    + flag "--priority" priority
    + tagFlags
    + flag "--click" click
    + flag "--attach" attach
    + actionFlags
    + flag "--delay" delay
    + flag "--timeout" timeout
    + lib.optionalString json "--json ";
}
