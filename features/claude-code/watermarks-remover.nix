/*
  watermarks-remover -- strips AI provenance marks and file metadata.

  Pinned to a commit, not a branch: upstream ships no tags, and the point of
  packaging it here rather than running `python3 install_skill.py` is that the
  version is part of the flake lock like everything else.

  Runtime is Python stdlib only -- requirements-dev.txt is pytest/ruff/pip-audit
  and is not installed. The PostToolUse hook is the one piece that needs node.
*/
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  python3,
  makeWrapper,
}:

let
  rev = "81d808d5d71bb22a02b1bdc3df293a2d93422778";
in
stdenvNoCC.mkDerivation {
  pname = "watermarks-remover";
  version = "0.7.0-unstable-2026-09-10";

  src = fetchFromGitHub {
    owner = "guillaumemeyer";
    repo = "watermarks-remover";
    inherit rev;
    hash = "sha256-e2/2+CBWkTwrUNvrwXSLbfk4q5fwtZXL/HNtHNEOl90=";
  };

  nativeBuildInputs = [ makeWrapper ];

  # The repo ships a Makefile whose default target runs pytest; the generic
  # builder would pick it up and fail on a sandbox without pytest.
  dontConfigure = true;
  dontBuild = true;

  # No build step: it is a source tree of stdlib Python. Vendor it whole so the
  # skills can reference sibling paths (service/scripts/*) the way upstream does.
  installPhase = ''
    runHook preInstall

    mkdir -p "$out/share/watermarks-remover"
    cp -r service skills config hooks .claude-plugin "$out/share/watermarks-remover/"

    # Expose the CLI scripts as wm-<name>, each on a stdlib python3.
    mkdir -p "$out/bin"
    for f in "$out/share/watermarks-remover"/service/scripts/*.py; do
      n="$(basename "$f" .py)"
      case "$n" in *_lib) continue ;; esac
      makeWrapper ${python3}/bin/python3 "$out/bin/wm-$n" \
        --add-flags "$f" \
        --set PYTHONPATH "$out/share/watermarks-remover"
    done

    runHook postInstall
  '';

  meta = {
    description = "Strip AI provenance marks (C2PA, invisible Unicode) and file metadata";
    homepage = "https://github.com/guillaumemeyer/watermarks-remover";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
