# rhwp's command-line tool, from the same patched fork HOP builds against
# (see flake.nix): reads HWP/HWPX and exports text, Markdown, SVG, PNG, PDF,
# HWPX and the document structure.  Default features only -- the skia
# renderer is optional and not needed for any of that.
{ lib, rustPlatform, rhwpSrc }:

rustPlatform.buildRustPackage {
  pname = "rhwp";
  version = (lib.importTOML "${rhwpSrc}/Cargo.toml").package.version;

  src = rhwpSrc;

  cargoLock = {
    lockFile = "${rhwpSrc}/Cargo.lock";
    # svg2pdf comes from a fork's branch (a deterministic-output patch).
    outputHashes."svg2pdf-0.13.0" = "sha256-j+FNAvnDr+xwTs6xrVVKrK8YDCNNeIlRUrWx0CDDofw=";
  };

  # Only the CLI; the crate also builds a font-metric generator and a wasm lib.
  cargoBuildFlags = [ "--bin" "rhwp" ];
  # The test suite renders sample documents and compares against checked-in
  # output; it is the upstream project's to run, not a packaging check.
  doCheck = false;

  meta = {
    description = "HWP/HWPX reader and converter (rhwp CLI)";
    homepage = "https://github.com/R0K0R/rhwp";
    license = lib.licenses.mit;
    mainProgram = "rhwp";
  };
}
