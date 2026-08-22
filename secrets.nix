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
      age-keygen -o /etc/agenix/identity.txt
    Copy the printed "Public key: age1..." into the bindings below, add it to
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
  galaxybook = "age1y70qjfcr9thkzk6nt4nd7mt0uj39jj6s2ye57elzej48z6q2ls4qdzs6zy";
  victus15 = "age1REPLACE_ME_WITH_VICTUS15_PUBLIC_KEY";

  allHosts = [
    galaxybook
    victus15
  ];
in
{
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
