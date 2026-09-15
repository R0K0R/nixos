{ config, inputs, lib, pkgs, ... }:

let
  cfg = config.my.kakaotalk;

  /*
    Wine comes from UPSTREAM nixpkgs, not this tree's package set, and the
    reason is structural rather than a preference.

    KakaoTalk PC is a 32-bit binary, so wine has to carry 32-bit support, which
    pulls in pkgsi686Linux, whose gcc wants multilib. gcc's builder asserts
    `!(enableMultilib && isCross)` -- and this tree is pseudo-cross, build and
    host sharing the config triple and differing only by -march, so isCross is
    true. `pkgs.wineWowPackages.stable` therefore fails at EVALUATION, before
    anything is built.

    pkgsBuildBuild clears that assertion but is still this tree's stdenv, so it
    rebuilds rustc, python3, perl, libjpeg-turbo and stdenv-linux from source
    for a package that gains nothing from any of it. Measured 2026-09-15.

    Upstream has neither problem and substitutes from cache.nixos.org. Fresh
    import rather than an overlay, same technique and same rationale as
    tuning/overlays/upstream-tools.nix: forcing `prev` mid-overlay-chain
    triggers real infinite recursion inside nixpkgs' internals.

    Nothing is lost by going untuned here -- wine executes Windows code, so
    -march=meteorlake on the wine binary itself buys nothing measurable.
  */
  upstream = import inputs.nixpkgs-upstream {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };

  # Bump: features/kakaotalk/update.sh.
  kakaotalk = pkgs.callPackage ./package.nix { wine = cfg.winePackage; };
in
{
  options.my.kakaotalk = {
    enable = lib.mkEnableOption ''
      KakaoTalk PC, the official Windows client, run under Wine

      The Android client is NOT an alternative here. Kakao permits one mobile
      device plus one PC simultaneously, and only the PC client is treated as a
      companion to the phone -- signing into the Android build (under Waydroid,
      say) registers a competing primary device and evicts the phone. The check
      happens server-side over a pinned TLS channel, so it cannot be worked
      around on the client
    '';

    winePackage = lib.mkOption {
      type = lib.types.package;
      default = upstream.wine;
      defaultText = lib.literalExpression "nixpkgs-upstream's wine (the 32-bit build)";
      description = ''
        The Wine build to run the client with.

        MUST carry 32-bit support: KakaoTalk PC is a 32-bit binary (note the
        `win32` in Kakao's download URL) and the launcher creates a win32
        prefix, so `wine64` cannot run it at all.

        Plain `wine` IS the 32-bit build on x86_64-linux, which is why it is the
        default rather than a wineWow* attribute. It is also the only one
        cache.nixos.org carries: wineWowPackages.stable builds wine from source
        (measured 2026-09-15), for a WoW64 layer a win32 prefix never uses.

        AND it must come from a package set that is not this tree's. See the
        comment above this option for why `pkgs.wineWowPackages.stable` cannot
        evaluate here and why pkgsBuildBuild, though it evaluates, is a
        from-source rebuild of half the toolchain.

        Worth reaching for the matching `staging` attribute if a release starts
        misbehaving; staging carries the patches that usually land such fixes
        first, at the cost of building from source.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ kakaotalk ];
  };
}
