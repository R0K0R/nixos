/*
  The account galaxybook4-pro360 is lent out on: the `handover` preset --
  a tmpfs home wiped at logout, one pinned program (firefox, the preset's),
  nothing else. Passwordless, so no per-lending credential either: the
  pinned program and the wiped home are the whole protection.
*/
{
  uid = 1003;
  type = "handover";
  description = "Handoff";
  passwordless = true;
}
