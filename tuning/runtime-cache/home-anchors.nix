/*
  Tier 3 anchors for packages that HOME features run, not system ones.

  Tier 3 anchors on every system feature's packages.nix (lookup.nix). When
  kitty, starship, eza, opencode and easyeffects moved from the system's
  features into r0k0r's home repo (2026-10-26), their packages.nix went with
  them, and the system cannot read a user repo -- so they silently stopped
  being anchors. On victus-15, where Tier 1 has never seen kitty (it only
  runs inside emacs there), kitty then fell out of the tuned set and took
  gtk, ffmpeg, opencv and the doom emacs build with it.

  The designed source for this evidence is the userCache (tuning-refresh,
  run as the user: it records what the user's home runs). Until those
  records cover a host, this list keeps the tuned set exactly what it was.
  Same rules as a packages.nix: plain-nixpkgs attributes only (freshPkgs).
*/
{ pkgs }:
with pkgs;
[
  kitty
  starship
  eza
  opencode
  opencode-claude-auth
  easyeffects
]
