/*
  The account galaxybook4-pro360 is lent out on: the `handover` preset --
  a tmpfs home wiped at logout, one pinned program (firefox, the preset's),
  nothing else. No password of its own: each lending gets a fresh one,
  `sudo handover issue handoff [--for "8 hours"]`, revoked with
  `sudo handover revoke handoff` (features/core/users/handover.nix).
*/
{
  uid = 1003;
  type = "handover";
  description = "Handoff";
}
