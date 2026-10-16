# Shows an image inline in a Claude Code reply under kitty: uploads it to the
# pty Claude Code runs on as a Unicode-placeholder virtual placement and prints
# the placeholder lines for Claude to copy into its answer. Meant for
# my.claude-code.extraBinPackages; the procedure lives in ~/.claude/CLAUDE.md.
{
  lib,
  runCommandLocal,
  makeBinaryWrapper,
  python3,
  imagemagick,
}:
runCommandLocal "kitty-inline-img"
  {
    nativeBuildInputs = [ makeBinaryWrapper ];
    meta.mainProgram = "kitty-inline-img";
  }
  ''
    install -Dm644 ${./kitty-inline-img.py} $out/libexec/kitty-inline-img.py
    makeWrapper ${python3.interpreter} $out/bin/kitty-inline-img \
      --add-flags $out/libexec/kitty-inline-img.py \
      --prefix PATH : ${lib.makeBinPath [ imagemagick ]}
  ''
