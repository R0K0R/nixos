# r0k0r's one-offs, moved from the hosts' my.packages.extra.user into his
# home's host files (2026-10-27): galaxybook4-pro360's list and victus-15's
# CUDA btop, verbatim, so they stay anchors as they were from the host files.
{ pkgs }:
{
  user = with pkgs; [
    yt-dlp
    mpv
    foliate
    localsend
    gws
    (btop.override { cudaSupport = true; })
  ];
}
