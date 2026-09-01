/*
  agenix recipient map. Read by the `agenix` CLI ONLY -- it is not part of any
  NixOS evaluation, is not a module, and nothing imports it. `agenix -e
  age/foo.age` looks for this file at the repo root, encrypts to every public
  key listed for that path, and re-encrypts on every edit.

  Everything here is PUBLIC key material. Committing it is the intended use.
  The matching private identities live at my.agenix.identityPaths
  (/etc/agenix/identity.txt), outside the flake, and must never be added --
  the repo is public, and a git flake would copy them into the world-readable
  store besides.

  ADDING A HOST
    On the host, as root:
      umask 077 && mkdir -p /etc/agenix
      ssh-keygen -t ed25519 -N "" -C agenix-identity -f /etc/agenix/identity-ed25519
    Copy the contents of the .pub into the bindings below, add it to
    the recipient list of every secret that host must read, then re-key the
    affected secrets:
      agenix -r          # re-encrypt everything to the current lists

  WHY AGE IDENTITIES RATHER THAN SSH HOST KEYS
    agenix's documented default encrypts to /etc/ssh/ssh_host_ed25519_key.pub,
    which presumes the host runs sshd. galaxybook4-pro360 does not, so it has
    no host key to use. See features/agenix/nixos.nix for the full note.

  PER-SECRET RECIPIENTS, NOT ONE GLOBAL LIST
    A secret is readable by exactly the machines that need it. The remote
    builder key is the clearest case: it is what galaxybook uses to DISPATCH
    builds, so victus-15 has no reason to hold it.
*/

let
  # --- host identities -------------------------------------------------
  # Replace the placeholders with the real `age-keygen` public keys. Left
  # as obviously-invalid strings on purpose: agenix fails loudly on a
  # malformed recipient, which is far better than silently encrypting to a
  # key nobody holds.
  /*
    An ed25519 SSH key, not a native age one, and not a host key either.

    WHY NOT A NATIVE AGE KEY. An age identity can only be backed up as a file,
    and that file then has to reach a new machine before anything decrypts --
    the one bootstrap step nothing in this repo could automate. An ed25519 key
    round-trips through `melt` to a 24-word BIP39 seed phrase, so the identity
    is recoverable from words.

    That is NOT a passphrase. The words ENCODE the existing 256-bit key rather
    than deriving one from human-chosen input, so the search space stays the
    key's own. The distinction matters because these ciphertexts live in a
    PUBLIC repo: an attacker gets unlimited offline attempts, which a
    memorable passphrase would not survive.

    WHY NOT THE SSH HOST KEY, which is agenix's documented default: that
    presumes the host runs sshd, and galaxybook4-pro360 does not. A standalone
    key from `ssh-keygen` needs no sshd -- agenix accepts any ed25519 private
    key as an identity. The old note here rejected host keys specifically, not
    ed25519 keys.

    No passphrase on the key itself: activation is unattended and agenix
    cannot prompt. The seed phrase is the backup, not a second factor.
  */
  galaxybook = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIPRLwavNlS/Oa3RqYJhgoLetQTlp9JzU9+l9Via1sUQ agenix-identity";
  victus15 = "age1REPLACE_ME_WITH_VICTUS15_PUBLIC_KEY";

  allHosts = [
    galaxybook
    victus15
  ];
in
{
  /*
    Account password hashes.

    ONE FILE PER ACCOUNT, SHARED ACROSS HOSTS -- r0k0r's password is the same
    on every machine, so a per-host copy was two files that had to be kept
    identical by hand. features/users derives the /run/agenix path from the
    username, so the name here is load-bearing.

    RECIPIENT LIST IS GALAXYBOOK-ONLY FOR NOW, which is why victus-15 still
    points at its untracked /etc/nixos/secrets files. victus15 above is still
    the age1REPLACE_ME placeholder, and encrypting to it would fail loudly (by
    design). Give victus-15 an ed25519 identity, put its public key above, and
    then change these two to allHosts -- at which point the untracked copies
    can go.

    DO NOT change victus-15 to passwordSecret before that: it sets
    users.mutableUsers = false, so a hashedPasswordFile that never decrypts
    means an unloginnable machine on the next switch.
  */
  "age/hashed-password-r0k0r.age".publicKeys = [ galaxybook ];
  "age/hashed-password-benjamin.age".publicKeys = [ galaxybook ];

  # Gnus/auth-source credentials (netrc format: imap.gmail.com and
  # smtp.gmail.com lines for both accounts). Consumed by Emacs running as
  # r0k0r, so the secret needs owner = "r0k0r" where it is declared.
  "age/authinfo.age".publicKeys = [ galaxybook ];

  # Tailscale pre-auth key -- features/headscale/nixos.nix authKeyFile.
  "age/tailscale-authkey.age".publicKeys = allHosts;

  # OpenVPN profile, credentials inline -- features/openvpn/nixos.nix.
  "age/openvpn-profile.age".publicKeys = [ galaxybook ];

  # SSH private key the nix-daemon uses to dispatch remote builds.
  # galaxybook only: it is the client here, victus-15 is the builder.
  #
  # MIGRATE THIS LAST, and keep the existing tmpfiles-provisioned copy until
  # the agenix path is proven: it is the key that dispatches builds, so
  # breaking it costs the ability to rebuild remotely -- including the
  # rebuild that would fix it.
  "age/remote-builder-ssh-key.age".publicKeys = [ galaxybook ];
}
