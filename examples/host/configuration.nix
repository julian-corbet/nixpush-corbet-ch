# examples/host/configuration.nix
#
# A minimal composed system exercising every real, implemented nixpush option, including the
# two opt-in guarantees (durable spool, channel fallback) -- used by `nix flake check`'s
# composed-host check (checks/default.nix's `modules-evaluate`). Every value here is generic
# and placeholder -- no real hostname, address, or topic ever belongs in this repo.
{ ... }:
{
  nixpush.enable = true;
  nixpush.defaultChannel = "alerts";

  nixpush.ntfy.enable = true;
  nixpush.ntfy.serverUrl = "https://ntfy.example.org";

  nixpush.channels.alerts = {
    provider = "ntfy";
    settings.topic = "REPLACE_ME_ALERTS_TOPIC";
    defaultPriority = "high";
  };

  # A paging channel that spools durably and degrades to "alerts" if its own secret failed
  # to unseal, or if ntfy hard-rejects it outright -- see README.md's "Durable channels" and
  # "Channel fallback" sections for what each of these two options actually buys.
  nixpush.channels.page = {
    provider = "ntfy";
    settings.topic = "REPLACE_ME_PAGE_TOPIC";
    secretFile = "/run/secrets/nixpush-page.env";
    defaultPriority = "urgent";
    durable = true;
    fallback = "alerts";
  };

  nixpush.flushInterval = "30s";

  # ── Stubs NixOS demands of any bootable system ───────────────────────────
  # tmpfs on / could never boot a real machine, which is the point: this
  # config exists to type-check the module, not to describe hardware.
  fileSystems."/" = {
    device = "nodev";
    fsType = "tmpfs";
  };

  boot.loader.grub = {
    enable = true;
    devices = [ "nodev" ];
  };

  networking.hostName = "example-node";
  system.stateVersion = "25.05";
}
