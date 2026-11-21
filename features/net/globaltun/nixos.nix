/*
  Full tunnel (TCP/UDP/QUIC/ICMP) out through an UNPRIVILEGED phone acting as the
  gateway, over an existing SSH path. On-demand, never auto-started:
  `sudo globaltun up` / `sudo globaltun down`.

    laptop --LAN--> [jumps...] --> gateway --> internet

  `jumps` is a list and may be empty, so both of these are the same module:

    laptop --LAN--> jump --OpenVPN--> phone (home wifi) --home ISP--> internet
    laptop --LAN--> server with its own uplink --ISP--> internet

  Why this shape rather than a VPN. The far end is Termux + proot-distro, where
  PRoot fakes uid 0 via ptrace but the kernel still sees an unprivileged uid: no
  CAP_NET_ADMIN, no CAP_NET_RAW, no tun device, and `ssh -w` is therefore
  impossible. The phone can only terminate and re-originate SOCKETS, never
  forward packets. Everything below follows from that one constraint.

  `ssh -L` carries TCP only and sshd will never sendto() on your behalf, so UDP
  and ICMP are multiplexed over TCP streams and re-emitted as real datagrams by
  a small static relay pushed onto the gateway (`relay/`), which is the only thing that
  runs there:

    SOCKS5 CONNECT                -> connect()                     [TCP]
    CONNECT udp.mux.arpa:1        -> sendto/recvfrom               [UDP, QUIC]
    CONNECT icmp.mux.arpa:1       -> unprivileged ping socket      [ICMP echo]

  Native SCTP and DCCP cannot work: Android's kernel has neither, and proot
  cannot load modules. Nor can anything needing raw IP (GRE, ESP/AH). WebRTC is
  fine -- its SCTP rides inside DTLS over UDP.

  sing-box is used LOCALLY only. It wedges on the phone ("initialize interface
  monitor take too much time"), staying alive with an empty log while refusing
  every connection, because Android blocks netlink enumeration for apps.

  Full write-up, including the two traps that cost the most time, lives in
  globaltun-findings.md at the repo root (gitignored).
*/
{ config, lib, pkgs, ... }:

let
  cfg = config.my.globaltun;

  /*
    Generated rather than shipped as a static file so the resolver cannot drift
    from the option, and so the ports stay in one place.

    "stack" MUST be gvisor. With auto_route off, the "system" stack silently
    drops TCP while UDP and ICMP still arrive -- the tun looks alive, packets
    demonstrably reach sing-box, and the log stays empty. The system stack needs
    the redirect rules auto_route installs; gvisor is self-contained.

    auto_route stays off deliberately: its ip rules sit near priority 9000 and
    lose to tailscale's 5210/5270, which breaks the tailnet. The wrapper script
    installs routes in `main` instead, so tailscale's fwmark rule 5210 lands its
    underlay in the tun and tailscale keeps working over DERP.

    DNS is DNS-over-HTTPS so name resolution never depends on the UDP path.
  */
  mkClientConfig = { quic ? false }: {
    log = { level = "info"; timestamp = true; };
    dns = {
      servers = [ { type = "https"; tag = "remote-dns"; server = cfg.dns; detour = "proxy"; } ];
      final = "remote-dns";
      strategy = "ipv4_only";
    };
    inbounds = [{
      type = "tun";
      tag = "tun-in";
      interface_name = "tun9";
      address = [ "172.19.0.1/30" ];
      mtu = 1400;
      auto_route = false;
      stack = "gvisor";
    }] ++ lib.optionals quic [{
      /*
        The system resolver's ONLY upstream while the tunnel is up: `up`
        points systemd-resolved here (a /run drop-in, `Domains=~.`), and
        every query is answered over DoH through the tunnel.

        Why loopback: a Wi-Fi roam is a sub-second gap that the tunnel
        rides out (QUIC and TCP retransmit; measured 2026-11-17: 29 roams in
        49 min on galaxybook, zero sing-box errors after them), but a plain
        DNS datagram lost in that gap is gone -- resolved times out, marks the
        server degraded, and lookups stall for 15-20 s. Over loopback nothing
        is ever lost, and the DoH request inside the tunnel is simply late by
        the gap. It also makes whatever DNS the local network hands out
        irrelevant while the tunnel is up.
      */
      type = "direct";
      tag = "dns-in";
      listen = "127.0.0.2";
      listen_port = 53;
    }];
    outbounds = (if quic then [
      {
        type = "hysteria2";
        tag = "quic";
        # Filled in by `up`: the resolved gateway address and the per-run
        # password. Placeholders rather than a runtime-generated file so the
        # rest of the config stays in the store, reviewable, and identical to
        # the ssh-only one.
        server = "@GT_QUIC_HOST@";
        server_port = cfg.quic.port;
        password = "@GT_QUIC_PASSWORD@";
        tls = {
          enabled = true;
          server_name = "globaltun";
          # Pinned: trusts exactly the certificate `up` generated, nothing else.
          certificate_path = "/run/globaltun-quic/cert.pem";
        };
      }
      { type = "socks"; tag = "ssh"; server = "127.0.0.1"; server_port = 1081; version = "5"; }
      {
        /*
          A plain switch, defaulting to QUIC; carrier-watch flips it (via the
          API below) to ssh when QUIC stops answering and BACK once QUIC is
          healthy again -- see transport_watch in globaltun.sh.

          It was a urltest, and that was wrong in a way that cost real time:
          urltest only leaves the current pick when another beats it by the
          tolerance, and the ssh probe can measure FASTER than QUIC even
          though QUIC moves 5-10x the data. So one QUIC hiccup parked traffic
          on ssh for good (seen on the Android client 2026-11-17: QUIC healthy,
          traffic still on ssh). No `fallback` type exists in this sing-box.
        */
        type = "selector";
        tag = "proxy";
        outbounds = [ "quic" "ssh" ];
        default = "quic";
        interrupt_exist_connections = true;
      }
    ] else [
      { type = "socks"; tag = "proxy"; server = "127.0.0.1"; server_port = 1081; version = "5"; }
    ]) ++ [
      { type = "direct"; tag = "direct"; }
    ];
    route = {
      rules = lib.optionals quic [
        { inbound = [ "dns-in" ]; action = "hijack-dns"; }
      ] ++ [
        { action = "sniff"; }
      ] ++ lib.optionals (!quic) [
        /*
          ssh only: answer every port-53 query HERE, over DoH, so resolution
          never rides the udp-over-tcp mux.

          NOT with QUIC, where UDP is native: there the queries pass through to
          the resolvers they were sent to, like any other datagram. Measured
          2026-11-17 on galaxybook: with the hijack, systemd-resolved logged
          "Using degraded feature set" for its upstreams 72 times an hour on
          the ssh transport and 47 in QUIC's first ten minutes, and a
          nixos-rebuild failed resolving cache.nixos.org -- the hijack, not
          the transport, was the common factor.
        */
        { protocol = "dns"; action = "hijack-dns"; }
      ] ++ [
        { ip_is_private = true; outbound = "direct"; }
        { ip_cidr = [ "100.64.0.0/10" ]; outbound = "direct"; }
      ];
      final = "proxy";
      auto_detect_interface = true;
    };
  } // lib.optionalAttrs quic {
    # For `status`/`verify` (which transport carries traffic, each one's delay)
    # and for carrier-watch, which flips the transport switch.
    # Loopback, but any local user could reach it, and it can now SWITCH the
    # transport -- so it takes the run's random secret (rendered by `up`).
    experimental.clash_api = {
      external_controller = "127.0.0.1:11090";
      secret = "@GT_API_SECRET@";
    };
  };

  clientConfig = pkgs.writeText "globaltun-client.json" (builtins.toJSON (mkClientConfig { }));
  quicClientConfig = pkgs.writeText "globaltun-client-quic.json"
    (builtins.toJSON (mkClientConfig { quic = true; }));

  /*
    PATH is pinned rather than inherited: this runs under sudo, and a root PATH
    missing iproute2 or iptables would fail halfway through bringing the tunnel
    up -- with routes already installed and no proxy behind them, which is the
    one failure mode that takes the machine offline.
  */
  /*
    The gateway half of the tunnel, built static for every architecture a
    gateway might be.

    This exists so the gateway needs NOTHING pre-installed. The Python relay it
    replaces is fine on a box that happens to ship python3, but "happens to" is
    the problem: the whole point of this design is that the gateway is some
    arbitrary machine we can only ssh into. With CGO off there is no libc, no
    dynamic loader and no interpreter behind the binary, so an sshd and a
    writable /tmp are the entire contract.

    Both architectures are built here, in one derivation, because Go
    cross-compiles with no cross toolchain at all once CGO is off -- so this
    costs a second `go build`, not a second stdenv. The script picks by the
    gateway's `uname -m` at runtime.
  */
  gtrelay = pkgs.stdenv.mkDerivation {
    pname = "gtrelay";
    version = "1";
    src = ./relay;
    nativeBuildInputs = [ pkgs.go ];
    # No module dependencies at all -- stdlib only -- so the build needs no
    # network and no vendor hash, and GOPROXY is pinned off to keep it honest.
    buildPhase = ''
      export HOME=$TMPDIR GOCACHE=$TMPDIR/go-cache GOPROXY=off CGO_ENABLED=0
      for arch in amd64 arm64; do
        GOOS=linux GOARCH=$arch \
          go build -trimpath -ldflags="-s -w" -o gtrelay-linux-$arch .
      done
    '';
    installPhase = ''
      mkdir -p $out/bin
      cp gtrelay-linux-amd64 gtrelay-linux-arm64 $out/bin/
    '';
    # The foreign-architecture binary would be mangled by the host's strip,
    # and -ldflags=-s -w has already done the stripping.
    dontFixup = true;
    meta.description = "static SOCKS5/UDP/ICMP relay pushed to a globaltun gateway";
  };

  /*
    The QUIC transport's gateway half: sing-box as a Hysteria2 server, built the
    way gtrelay is and for the same reason -- static, both architectures, pushed
    over the ssh master, so the gateway still needs nothing installed.

    NOT pkgs.sing-box itself: that one is CGO-enabled (it needs the store's
    glibc loader, which a foreign gateway does not have) and 110MB with every
    protocol compiled in. This reuses its source and vendored modules, so the
    two cannot drift apart in version, and builds only `with_quic`: ~40MB
    (sing-box's core is most of it), pushed once per binary per gateway --
    content-addressed, like the relay. Seconds over a LAN; minutes over a
    slow phone path, once.

    -checklinkname=0 and the two link tags are what nixpkgs builds with; the
    quic-go fork sing-box vendors relies on linkname into the runtime.
  */
  gtquic = pkgs.stdenv.mkDerivation {
    pname = "gtquic";
    inherit (pkgs.sing-box) version src;
    nativeBuildInputs = [ pkgs.sing-box.go ];
    buildPhase = ''
      export HOME=$TMPDIR GOCACHE=$TMPDIR/go-cache GOPROXY=off GOFLAGS=-mod=vendor CGO_ENABLED=0
      cp -r ${pkgs.sing-box.goModules} vendor
      chmod -R u+w vendor
      for arch in amd64 arm64; do
        GOOS=linux GOARCH=$arch go build -trimpath \
          -tags with_quic,badlinkname,tfogo_checklinkname0 \
          -ldflags="-s -w -checklinkname=0 -X=github.com/sagernet/sing-box/constant.Version=${pkgs.sing-box.version}" \
          -o gtquic-linux-$arch ./cmd/sing-box
      done
    '';
    installPhase = ''
      mkdir -p $out/bin
      cp gtquic-linux-amd64 gtquic-linux-arm64 $out/bin/
    '';
    dontFixup = true;
    meta.description = "static sing-box (Hysteria2 server only) pushed to a globaltun gateway";
  };

  /*
    A hop is either the plain string form -- what globaltun.sh parses, and what
    a standalone globaltun.env writes -- or an attrset that renders to it. The
    attrset exists so a password FILE and a hop kind are fields with types and
    assertions, rather than syntax someone has to get right inside a string.
  */
  hopType = lib.types.submodule {
    options = {
      host = lib.mkOption {
        type = lib.types.str;
        example = "admin@10.0.0.9:2222";
        description = "`[user@]host[:port]`. A proxy hop needs the port.";
      };
      kind = lib.mkOption {
        type = lib.types.enum [ "ssh" "socks5" "http" ];
        default = "ssh";
        description = ''
          `ssh` is a jump host. `socks5` and `http` are proxies that open the
          next connection on our behalf -- SOCKS5 (with the target resolved on
          the proxy, socks5h-style) or HTTP CONNECT. Tor is a `socks5` hop on
          127.0.0.1:9050.
        '';
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/run/agenix/jump-password";
        description = ''
          File holding this hop's password, read at runtime. For an ssh hop it
          replaces key auth; for a proxy it is the proxy's own credential and
          needs a `user@` in `host`. A STRING, never a path literal, for the
          same reason as `sshKey`: a path literal would copy the secret into
          the world-readable store.
        '';
      };
      sshKey = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "A key of this hop's own, instead of the top-level `sshKey`. ssh hops only.";
      };
    };
  };

  renderHop = h:
    if builtins.isString h then h
    else (lib.optionalString (h.kind != "ssh") "${h.kind}://") + h.host
      + (if h.passwordFile != null then "=password:${h.passwordFile}"
         else if h.sshKey != null then "=key:${h.sshKey}"
         else "");

  # Hops travel as one space-separated variable, so these characters would
  # silently split or re-parse a hop into something else.
  badHopChars = v: v != null && builtins.match ".*[[:space:],=].*" v != null;

  hopAssertions = lib.concatMap (h: lib.optionals (!builtins.isString h) [
    {
      assertion = h.passwordFile == null || h.sshKey == null;
      message = "my.globaltun.jumps: hop ${h.host} sets both passwordFile and sshKey; pick one.";
    }
    {
      assertion = h.kind == "ssh" || h.sshKey == null;
      message = "my.globaltun.jumps: hop ${h.host} is a ${h.kind} proxy; sshKey applies to ssh hops only.";
    }
    {
      assertion = h.kind == "ssh" || h.passwordFile == null || lib.hasInfix "@" h.host;
      message = "my.globaltun.jumps: proxy hop ${h.host} has a passwordFile but no user@ to go with it.";
    }
    {
      assertion = !(badHopChars h.host || badHopChars h.passwordFile || badHopChars h.sshKey);
      message = "my.globaltun.jumps: hop ${h.host} contains whitespace, ',' or '=', which would split it.";
    }
  ]) cfg.jumps;

  runtimeDeps = with pkgs; [
    openssh iproute2 iptables nftables python3 sing-box
    coreutils gnugrep gnused gawk procps iputils curl
    iw hostapd dnsmasq util-linux
  ];

  globaltun = pkgs.writeShellScriptBin "globaltun" (''
    export PATH=${lib.makeBinPath runtimeDeps}:$PATH
    export GT_JUMPS=${lib.escapeShellArg (lib.concatMapStringsSep " " renderHop cfg.jumps)}
    export GT_GTCONNECT=${./gtconnect.py}
    export GT_RHOST=${lib.escapeShellArg cfg.remote}
    export GT_RPORT=${toString cfg.remotePort}
    export GT_JUMP_TIMEOUT=${toString cfg.jumpConnectTimeout}
    export GT_REMOTE_SOCKS_PORT=${toString cfg.remoteSocksPort}
    export GT_KEEP_DIRECT=${lib.escapeShellArg (lib.concatStringsSep " " cfg.keepDirect)}
    export GT_KEY=${lib.escapeShellArg cfg.sshKey}
    export GT_ICMP=${if cfg.icmp.enable then "1" else "0"}
    export GT_TAILSCALE_DIRECT=${if cfg.tailscaleDirect then "1" else "0"}
    # Only to WARN on `up` when the zone being frozen is not this one -- never
    # to set it. A different zone is either a real trip or a poisoned fix, and
    # only the person at the keyboard knows which.
    export GT_TZ_HOME=${lib.escapeShellArg (config.my.locale.timeZone or "")}
    export GT_RELAY_DIR=${gtrelay}/bin
    export GT_RSOCKS=${./rsocks.py}
    export GT_GTLOCAL=${./gtlocal.py}
    export GT_GTICMP=${./gticmp.py}
    export GT_VERIFY=${./verify.py}
    export GT_SBCONF=${clientConfig}
    export GT_SINGBOX=${pkgs.sing-box}/bin/sing-box
    export GT_DNS=${lib.escapeShellArg cfg.dns}
    export GT_SHARE=${if cfg.share.enable then "1" else "0"}
    export GT_QUIC=${if cfg.quic.enable then "1" else "0"}
    export GT_PIN_AP=${if cfg.pinAccessPoint then "1" else "0"}
    '' + lib.optionalString cfg.quic.enable ''
      # Only when on: quic.port has no default, and the QUIC config and the
      # gateway binaries are only worth building for a host that uses them.
      export GT_QUIC_PORT=${toString cfg.quic.port}
      export GT_QUIC_HOST=${lib.escapeShellArg (if cfg.quic.host != null then cfg.quic.host else "")}
      export GT_QUIC_BIN_DIR=${gtquic}/bin
      export GT_SBCONF_QUIC=${quicClientConfig}
    '' + lib.optionalString cfg.share.enable ''
      # Emitted only when sharing is on. passwordFile, stationInterface and
      # countryCode deliberately have no defaults, so interpolating them
      # unconditionally makes every host without sharing fail to evaluate.
      export GT_SHARE_SSID=${lib.escapeShellArg cfg.share.ssid}
      export GT_SHARE_PSK_FILE=${lib.escapeShellArg cfg.share.passwordFile}
      export GT_SHARE_STA=${lib.escapeShellArg cfg.share.stationInterface}
      export GT_SHARE_AP=${lib.escapeShellArg cfg.share.apInterface}
      export GT_SHARE_ADDR=${lib.escapeShellArg cfg.share.address}
      export GT_SHARE_DHCP=${lib.escapeShellArg cfg.share.dhcpRange}
      export GT_SHARE_COUNTRY=${lib.escapeShellArg cfg.share.countryCode}
    '' + ''
    ${builtins.readFile ./globaltun.sh}
  '');
  /*
    Decides, on every network event and on a timer, whether the tunnel should be
    carrying traffic. Kept OUT of globaltun.sh: that script is a manual tool and
    stays usable on a machine with no NetworkManager.

    The probe is the whole difficulty. Once the tunnel is up, any ordinary
    connectivity check succeeds THROUGH it and would immediately tear it back
    down, so the probe is bound to the physical device with SO_BINDTODEVICE
    (`curl --interface`, which needs root to bind by device rather than by
    address) and therefore ignores the routing table entirely.

    Hysteresis is asymmetric on purpose. Bringing the tunnel up hijacks the
    default route onto a path that is TCP-over-TCP through a ptraced proot, so
    a transient blip must not flap traffic onto it: that demands
    ${toString cfg.auto.failures} consecutive failures. Tearing it down only
    restores normal routing, so one success is enough.
  */
  autoScript = pkgs.writeShellScriptBin "globaltun-auto" ''
    set -uo pipefail
    export PATH=${lib.makeBinPath (runtimeDeps ++ [ globaltun pkgs.networkmanager pkgs.util-linux ])}:$PATH

    # NM dispatcher and the timer can fire together; serialise them.
    exec 9>/run/globaltun-auto.lock
    flock -n 9 || exit 0

    want=(${lib.escapeShellArgs cfg.auto.ssids})
    # tab-separated: SSIDs may contain spaces, which would split the read
    IFS=$'\t' read -r ssid dev < <(nmcli -t -f ACTIVE,SSID,DEVICE dev wifi 2>/dev/null \
                                    | awk -F: '$1=="yes"{print $2"\t"$3; exit}')
    [ -n "''${dev:-}" ] || { logger -t globaltun-auto "no active wifi; leaving tunnel alone"; exit 0; }

    match=0
    for w in "''${want[@]}"; do [ "$ssid" = "$w" ] && match=1; done

    if [ "$match" = 0 ]; then
      if globaltun is-up; then
        logger -t globaltun-auto "ssid $ssid is not managed; tearing down"
        globaltun down
      fi
      exit 0
    fi

    probe(){ curl -sf --interface "$dev" -m ${toString cfg.auto.probeTimeout} \
               -o /dev/null ${lib.escapeShellArg cfg.auto.probeUrl}; }

    if probe; then
      if globaltun is-up; then
        logger -t globaltun-auto "$ssid uplink recovered; tearing down"
        globaltun down
      fi
      exit 0
    fi

    globaltun is-up && exit 0

    n=1
    while [ "$n" -lt ${toString cfg.auto.failures} ]; do
      sleep 3
      probe && { logger -t globaltun-auto "$ssid uplink came back; not starting"; exit 0; }
      n=$((n + 1))
    done

    logger -t globaltun-auto "$ssid has no uplink after $n probes; bringing tunnel up"
    # Short budget: the timer retries, so a dead jump host must not hold the
    # lock for the 30 minutes the manual escalation would allow.
    GT_TIMEOUTS=${lib.escapeShellArg cfg.auto.connectTimeouts} globaltun up \
      || logger -t globaltun-auto "bring-up FAILED; will retry on next tick"
  '';

  # my.globaltun.schedule: the tunnel up for a fixed nightly window, on the
  # listed SSIDs only. It only ever tears down a tunnel it brought up itself,
  # recorded as the window's start date in a /run marker (gone at reboot).
  scheduleScript = pkgs.writeShellScriptBin "globaltun-schedule" ''
    set -uo pipefail
    export PATH=${lib.makeBinPath (runtimeDeps ++ [ globaltun pkgs.networkmanager pkgs.util-linux ])}:$PATH
    exec 9>/run/globaltun-schedule.lock
    flock -n 9 || exit 0
    log(){ logger -t globaltun-schedule "$*"; }

    mins(){ local h=''${1%%:*} m=''${1##*:}; echo $(( 10#$h * 60 + 10#$m )); }
    up=$(mins ${lib.escapeShellArg cfg.schedule.up})
    down=$(mins ${lib.escapeShellArg cfg.schedule.down})
    now=$(mins "$(date +%H:%M)")
    # The window may wrap midnight (01:50-06:10 does not; 23:00-06:00 would).
    # A window is named by the date it started, so one that wraps is the same
    # window on both sides of midnight.
    if [ "$up" -le "$down" ]; then
      inwin=$(( now >= up && now < down )); win=$(date +%F)
    else
      inwin=$(( now >= up || now < down ))
      if [ "$now" -ge "$up" ]; then win=$(date +%F); else win=$(date -d yesterday +%F); fi
    fi

    marker=/run/globaltun-schedule.window
    ours=0; [ "$(cat "$marker" 2>/dev/null)" = "$win" ] && ours=1

    teardown(){  # only a tunnel this schedule started
      if [ -e "$marker" ]; then
        if globaltun is-up; then log "$1; tearing down"; globaltun down; fi
        rm -f "$marker"
      fi
    }

    if [ "$inwin" = 0 ]; then teardown "window over"; exit 0; fi

    want=(${lib.escapeShellArgs cfg.schedule.ssids})
    ssid=$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}')
    match=0
    for w in "''${want[@]}"; do [ "$ssid" = "$w" ] && match=1; done
    if [ "$match" = 0 ]; then teardown "left the scheduled SSIDs (now: ''${ssid:-none})"; exit 0; fi

    # Already started this window: nothing more. A `globaltun down` by hand
    # then sticks until the next window instead of being undone every tick.
    [ "$ours" = 1 ] && exit 0
    # Up by hand before the window: the person's tunnel, left alone (and so
    # not torn down at the window's end either).
    globaltun is-up && exit 0

    log "window $win on $ssid; bringing tunnel up"
    if GT_TIMEOUTS=${lib.escapeShellArg cfg.schedule.connectTimeouts} globaltun up; then
      echo "$win" > "$marker"
    else
      log "bring-up FAILED; will retry on next tick"
    fi
  '';
in
{
  options.my.globaltun = {
    enable = lib.mkEnableOption ''
      an on-demand full tunnel through a phone gateway, reached via an SSH jump
      host. Defines the `globaltun` command; starts nothing. Bring it up with
      `sudo globaltun up` and check it with `sudo globaltun verify`
    '';

    jumps = lib.mkOption {
      type = lib.types.listOf (lib.types.either lib.types.str hopType);
      default = [ ];
      example = lib.literalExpression ''
        [
          "user@192.0.2.1"                                     # ssh, sshKey
          { host = "admin@10.0.0.9:2222"; passwordFile = "/run/agenix/jump-pw"; }
          { kind = "http"; host = "proxyuser@proxy.corp:3128"; passwordFile = "/run/agenix/proxy-pw"; }
          { kind = "socks5"; host = "127.0.0.1:9050"; }        # Tor
        ]
      '';
      description = ''
        Hops between this machine and `remote`, nearest first: this machine
        reaches `jumps` head-first and the last one reaches the gateway. A
        plain string is an ssh hop, `[user@]host[:port]`, using `sshKey`; an
        attrset (see the example) can make a hop a SOCKS5 or HTTP CONNECT proxy
        and give any hop its own credentials.

        Kinds mix freely: a proxy can come first (a corporate HTTP proxy in
        front of everything), last (a SOCKS proxy that only the final jump can
        reach), or between ssh hops. Every hop must carry a TCP stream -- that
        is what ssh rides -- so UDP-only transports cannot be hops.

        Empty -- the default -- means this machine dials the gateway itself.
        That is a normal configuration, not a degenerate one: it is what you
        want whenever the gateway is directly reachable, including the case
        where the gateway is simply a machine that has internet.

        Every hop gets its credentials through a generated ssh config, one
        ProxyCommand per hop, rather than `-J`: ssh(1) applies command-line
        options to the DESTINATION only, so under a bare `-J` list each hop
        falls back to an interactive password prompt nothing can answer. See
        `sshKey` for why that is worse than it sounds. `sudo globaltun probe`
        walks the whole chain without creating a tun, and `globaltun hop N`
        opens a shell on one hop through the ones before it.
      '';
    };

    jumpConnectTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = ''
        ConnectTimeout for each jump hop, in seconds. Ignored when `jumps` is
        empty.

        Separate from the gateway's own budget (GT_TIMEOUTS, 300/600/900)
        because the two fail differently: the gateway is slow because every
        syscall there is ptraced by proot, whereas a slow jump host means a
        loaded or marginally-reachable machine, which is worth waiting out
        rather than failing fast and retrying the whole chain.
      '';
    };

    remote = lib.mkOption {
      type = lib.types.str;
      example = "root@192.0.2.50";
      description = ''
        The gateway, `user@host`, as reached from the LAST entry in `jumps` --
        or from this machine when `jumps` is empty.

        It needs nothing installed beyond an sshd and a writable /tmp: the
        relay is pushed in as a static binary.
      '';
    };

    remotePort = lib.mkOption {
      type = lib.types.port;
      default = 8022;
      description = "sshd port on the gateway. 8022 is the Termux default.";
    };

    sshKey = lib.mkOption {
      type = lib.types.str;
      example = "/run/agenix/globaltun-key";
      description = ''
        Private key authenticating to the gateway and to every ssh hop that
        does not set credentials of its own, read at runtime from outside the
        store.

        Each hop gets it through a generated ssh config -- one `Host` block per
        jump, chained with ProxyJump -- rather than through `-J`, because
        ssh(1) applies command-line options to the DESTINATION only: under `-J`
        the hops silently fall back to password auth on every connection. Each prompt then holds an unauthenticated slot on the jump
        host's sshd for the whole LoginGraceTime, and enough of them at once
        crosses the default MaxStartups, at which point that host starts
        dropping NEW connections from this machine entirely -- which looks like
        a network outage and heals by itself, so it is easy to misdiagnose.

        A STRING, not a path literal -- `./key` would be copied into the
        world-readable Nix store. The type forbids expressing that at all.
      '';
    };

    remoteSocksPort = lib.mkOption {
      type = lib.types.port;
      example = 1080;
      description = ''
        Port the relay listens on ON THE GATEWAY, and the suffix of its pidfile
        and log there.

        Deliberately has NO default. It must differ per client: several machines
        tunnelling through one gateway would otherwise share a single relay and
        pidfile, and whichever ran `up` last would kill the others' relay along
        with every connection on it -- silently, since nothing on either side
        reports it.

        A default would make that the failure mode of simply enabling the
        feature on a new host. This module cannot assert against a collision
        because it sees only its own host's config, so the check has to be a
        human one, and a required option is what forces it.

        The allocation is per gateway, and the gateway is now yulee -- 1080
        galaxybook4-pro360, 1082 victus-15, 1084 (Android client, see android/),
        1085 (Windows client, see windows/). Next free: 1086.

        1081 and 1083 are left unclaimed on purpose: they were yulee's own
        standalone bundle and a peer outside this flake, both back when note10
        was the gateway. Reusing them would make an old note10 relay and a new
        yulee one answer to the same number.

        Check the gateway before claiming one -- `pgrep -f 'gtrelay|rsocks'`
        there lists what is actually running. On a proot gateway `ss` is blind
        (Android blocks netlink for apps), so `pgrep` is the only honest check
        and the pidfiles in /tmp are the next best.
      '';
    };

    tailscaleDirect = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Keep tailscale's WireGuard underlay on the physical link instead of
        letting it ride the tunnel.

        Tailscale marks its own traffic 0x80000 and its rule at priority 5210
        sends that to `main`, where globaltun's `0.0.0.0/1` beats the default --
        so without this the underlay goes through the tunnel, STUN reports the
        GATEWAY's public address, and no peer can reach it. Two machines on one
        LAN then relay to each other through a DERP server on another
        continent: measured here as `relay "sin"` with 9.6GB moved that way,
        versus `direct` at 3-6ms once the bypass is on.

        Only the LAN prefix is bypassed: the control plane, DERP and off-LAN
        peers still ride the tun (a default route here once sent login to
        controlplane.tailscale.com straight out of a network that blocks it, and
        `tailscale login` hung). Default false all the same; turn it on where
        the peers that matter are on the same LAN.

        A host whose `keepDirect` already covers its LAN gets the on-LAN half
        of this for free -- that prefix sits in `main` and outranks
        `0.0.0.0/1` -- so the switch may not be needed on both ends of a pair.
      '';
    };

    keepDirect = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "192.0.2.0/24" ];
      description = ''
        Prefixes frozen onto the path they already use, instead of being
        swallowed by the tunnel.

        Two things belong here. On a headless machine, the network the admin
        session arrives over -- otherwise `up` cuts the connection mid-command
        and nothing is left running to undo it. And the underlay of any VPN the
        carrier depends on: routing that into the tunnel it carries survives
        only until the next rekey, and then cannot re-establish.
      '';
    };

    dns = lib.mkOption {
      type = lib.types.str;
      default = "1.1.1.1";
      description = "Upstream resolver, queried over DNS-over-HTTPS through the tunnel.";
    };

    auto = {
      enable = lib.mkEnableOption ''
        bringing the tunnel up automatically when a managed SSID has no uplink
        of its own, and tearing it down again when the uplink returns.

        Off by default because it hijacks the default route on a heuristic,
        onto a path several times slower than any working uplink. With it on, a
        manual
        `globaltun down` is undone by the next tick if the conditions still
        hold -- pin it off with `systemctl stop globaltun-auto.timer`
      '';

      ssids = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "KSA" ];
        description = ''
          Wi-Fi networks this applies to. Everywhere else the tunnel is left
          alone, and an already-running tunnel is torn down on arrival.

          A list rather than "any network without an uplink": a captive portal
          reads as no-uplink, and silently tunnelling out of an unknown network
          is a worse failure than staying offline.
        '';
      };

      probeUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://1.1.1.1/";
        description = ''
          Reachability probe for the PHYSICAL uplink. Requested with
          `curl --interface <dev>`, which as root binds by device
          (SO_BINDTODEVICE) and so bypasses the routing table -- without that
          the probe would succeed through the tunnel and tear it straight down.

          An IP literal, not a name: the interesting case is a network where
          DNS itself does not work.
        '';
      };

      probeTimeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 6;
        description = "Seconds allowed per probe.";
      };

      failures = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = ''
          Consecutive failed probes before the tunnel is brought up. Teardown
          needs only one success: starting moves traffic onto a much slower
          path, stopping only restores normal routing.
        '';
      };

      connectTimeouts = lib.mkOption {
        type = lib.types.str;
        default = "120";
        description = ''
          GT_TIMEOUTS for automatic bring-up. Deliberately far shorter than the
          manual default (300/600/900): proot's slow login justifies a long wait
          when a person is watching, but here a dead jump host would hold the
          lock and block every later tick.
        '';
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "2min";
        description = ''
          Timer period. A safety net only -- the NetworkManager dispatcher is
          what reacts promptly; this catches an uplink that dies without any
          link-state change.
        '';
      };
    };

    schedule = {
      enable = lib.mkEnableOption ''
        the tunnel up every night from `up` to `down`, on the listed SSIDs only
        (KSA's network curfew: no new connections from 02:00 to 06:00). It
        tears down only a tunnel it started itself: one brought up by hand is
        left alone, a `globaltun down` by hand sticks until the next night,
        and leaving the SSIDs ends it early. Checked every 5 minutes and at
        `up` and `down` exactly, so a machine waking mid-window catches up'';

      ssids = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "KSA" ];
        description = "Wi-Fi networks the schedule applies on; anywhere else it does nothing.";
      };

      up = lib.mkOption {
        type = lib.types.strMatching "[0-2][0-9]:[0-5][0-9]";
        default = "01:50";
        description = "Start of the window, HH:MM local time (curfew 02:00, with a 10-minute lead).";
      };

      down = lib.mkOption {
        type = lib.types.strMatching "[0-2][0-9]:[0-5][0-9]";
        default = "06:10";
        description = "End of the window, HH:MM local time (curfew ends 06:00, plus 10 minutes).";
      };

      connectTimeouts = lib.mkOption {
        type = lib.types.str;
        default = cfg.auto.connectTimeouts;
        defaultText = lib.literalExpression "config.my.globaltun.auto.connectTimeouts";
        description = "GT_TIMEOUTS for the scheduled bring-up; short, as the next tick retries.";
      };
    };

    share = {
      enable = lib.mkEnableOption ''
        `globaltun share`, which hosts a Wi-Fi AP on this machine's own card and
        routes its clients through the tunnel. Nothing starts automatically;
        `share` is a separate verb from `up` because the tunnel is useful
        without it and this touches the radio, the firewall and forwarding
      '';

      ssid = lib.mkOption {
        type = lib.types.str;
        default = "globaltun";
        description = "SSID of the hosted network.";
      };

      passwordFile = lib.mkOption {
        type = lib.types.str;
        example = "/run/agenix/globaltun-psk";
        description = ''
          File holding the WPA2 passphrase, read at runtime. A STRING path, not
          a path literal, and never the passphrase itself: either would put a
          shared secret in the world-readable Nix store.

          Minimum 8 characters; `share` refuses shorter ones rather than letting
          hostapd fail obscurely later.
        '';
      };

      stationInterface = lib.mkOption {
        type = lib.types.str;
        example = "wlo1";
        description = ''
          The interface that stays connected upstream. The AP is created as a
          second virtual interface on the same radio and MUST use this one's
          current channel -- the phy allows `#channels <= 1` -- so the channel
          is read when `share` runs, and `share`'s watcher moves the AP along
          when this one switches channel or roams.
        '';
      };

      apInterface = lib.mkOption {
        type = lib.types.str;
        default = "ap0";
        description = "Name of the virtual AP interface to create.";
      };

      address = lib.mkOption {
        type = lib.types.str;
        default = "10.42.0.1/24";
        description = "Address on the AP interface; also the clients' gateway.";
      };

      dhcpRange = lib.mkOption {
        type = lib.types.str;
        default = "10.42.0.50,10.42.0.150,12h";
        description = ''
          dnsmasq `--dhcp-range` for AP clients.

          DHCP is not optional in practice: Windows has no static fallback, so
          without a server it self-assigns an APIPA address and reports "no
          internet" while remaining happily associated.
        '';
      };

      countryCode = lib.mkOption {
        type = lib.types.str;
        example = "KR";
        description = ''
          Regulatory domain for hostapd. Required: without it the 5 GHz
          channels the station is likely using are unavailable to the AP.
        '';
      };
    };

    icmp.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Relay ICMP echo, so `ping` and `traceroute` report the real path rather
        than being answered locally by sing-box.

        Separable because it is the only part that touches policy routing and
        the firewall: it adds a second tun, an `ipproto icmp` rule, a routing
        table, and an interface-scoped netfilter exemption. TCP, UDP and QUIC do
        not depend on it.
      '';
    };

    pinAccessPoint = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        For a machine that does not move: while the tunnel is up, hold its
        Wi-Fi on the access point it was on at `up`, instead of letting it
        roam between APs of the same network. `down` releases it.

        Why: every roam is a gap, and on a campus network with several APs at
        similar strength the station roams constantly (galaxybook measured 7-11
        roams per 10 min on 2026-11-17). A stationary host gains nothing from
        roaming and loses every gap.

        How: NetworkManager's BSSID for the active connection, set with
        `nmcli connection modify --temporary` -- in memory only, so a reboot or
        NetworkManager restart can never leave it pinned. NetworkManager cannot
        apply a BSSID live, so `up` reconnects once, BEFORE the tunnel starts;
        if that reconnect fails the pin is dropped and the link restored.
        carrier-watch also drops it if the pinned AP is gone for 90 s, so a
        rebooted or replaced AP cannot strand a headless box.

        Requires NetworkManager. Laptops: leave it off.
      '';
    };

    quic = {
      enable = lib.mkEnableOption ''
        a second transport ALONGSIDE the ssh one: a Hysteria2 (QUIC) server
        pushed to the gateway over the ssh master, which the local sing-box
        dials directly over UDP.

        Expansion, not replacement. The ssh path is built exactly as before and
        stays up; the client holds both behind a switch that defaults to QUIC,
        and carrier-watch probes QUIC every 5 s: two failures move traffic to
        ssh, three successes move it back. ICMP keeps
        riding gticmp over ssh. When QUIC cannot start at all -- the gateway
        will not run the binary, or its port is filtered -- `up` says so and
        carries on ssh-only, so turning this on can never make `up` fail where
        it used to work.

        Why it exists: the ssh path is TCP carrying TCP (two congestion loops
        on the same loss) and carries every UDP flow on ONE stream, so a stall
        anywhere stalls everything. QUIC gives each flow its own stream and UDP
        stays datagrams. It needs what ssh does not: the gateway must be
        reachable over UDP from here, directly. That rules out a gateway behind
        ssh jumps (set `host` to an address that is reachable) and is worth
        checking on a new network before relying on it.

        Credentials are per `up`: a fresh self-signed certificate (which the
        client pins -- it trusts that one certificate and nothing else) and
        password, generated into /run, pushed to the gateway, deleted on
        `down`. Nothing to provision, persist or leak.
      '';

      port = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        example = 41080;
        description = ''
          UDP port the QUIC server binds ON THE GATEWAY (all addresses). Like
          `remoteSocksPort`, it must differ per client sharing a gateway --
          `up` on one would otherwise kill the other's server -- and so has no
          default. Convention on yulee: 40000 + remoteSocksPort, i.e. 41080
          galaxybook4-pro360, 41082 victus-15, 41084 the Android client (android/).
        '';
      };

      host = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "192.0.2.10";
        description = ''
          Address to dial the QUIC server at. Default: the host part of
          `remote`. Resolved once, before the tunnel routes exist, and pinned
          to the physical path like the ssh carrier is.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # The keys are hand-installed files outside the store: under impermanence
    # they went with the first wipe (2026-10-24) and the tunnel could not log
    # in. agenix paths (/run/...) are rebuilt every boot and need nothing.
    # Same for the hand-written passphrases: a hop's passwordFile, and share's
    # PSK (/etc/globaltun-psk), which a reboot would otherwise wipe.
    my.state.system.secret.files = lib.filter (k: k != null && !lib.hasPrefix "/run/" k)
      ([ cfg.sshKey ]
        ++ map (j: j.sshKey or null) cfg.jumps
        ++ map (j: j.passwordFile or null) cfg.jumps
        ++ lib.optional cfg.share.enable cfg.share.passwordFile);

    /*
      NetworkManager must never touch the AP interface. It matches saved
      profiles against ANY available wifi device, so on a card that permits two
      managed interfaces (MediaTek does; Intel does not) it will happily
      autoconnect the newly created ap0 to the upstream network and move the
      default route onto it -- leaving the machine online via the interface
      that was supposed to be serving clients, with hostapd running against a
      device NM has taken over.
    */
    networking.networkmanager.unmanaged =
      lib.mkIf cfg.share.enable [ "interface-name:${cfg.share.apInterface}" ];

    /*
      Root-only by construction: no setuid helper and no polkit rule,
      deliberately. Bringing this up rewrites the default route.
    */
    environment.systemPackages = [ globaltun ] ++ lib.optional cfg.auto.enable autoScript;

    /*
      While the tunnel is up, automatic-timezoned must not be able to START,
      not merely be stopped.

      `up` stops it because a full tunnel makes geolocation resolve the
      gateway's egress (a Cloudflare address one database places in Gabon).
      But stopping is undone by anything that starts units: measured, a
      `nixos-rebuild switch` started it 9 seconds after activation with the
      tunnel still up, it set Africa/Libreville 10 seconds later, and the next
      `up` then froze that poisoned value in place.

      So the marker `up` writes becomes a start condition. A condition is
      checked on EVERY start job -- switch-to-configuration, a manual
      `systemctl start`, boot -- and /run is cleared on reboot, which is the
      tunnel's own lifetime. A drop-in condition rather than `systemctl mask
      --runtime`, because a runtime mask lives in /run/systemd/system, which
      ranks BELOW /etc/systemd/system where NixOS puts this unit, so the mask
      would be silently shadowed.
    */
    systemd.services.automatic-timezoned =
      lib.mkIf config.services.automatic-timezoned.enable {
        unitConfig.ConditionPathExists = "!/run/globaltun.tzfreeze";
      };

    assertions = [
      {
        assertion = !cfg.share.enable || cfg.share.passwordFile != "";
        message = "my.globaltun.share.enable requires my.globaltun.share.passwordFile";
      }
      {
        assertion = !cfg.share.enable || cfg.share.stationInterface != "";
        message = "my.globaltun.share.enable requires my.globaltun.share.stationInterface (the upstream Wi-Fi interface whose channel the AP must follow)";
      }
      {
        assertion = !cfg.share.enable || cfg.share.countryCode != "";
        message = "my.globaltun.share.enable requires my.globaltun.share.countryCode (hostapd needs a regulatory domain for 5 GHz)";
      }
      {
        assertion = !cfg.quic.enable || cfg.quic.port != null;
        message = "my.globaltun.quic.enable requires my.globaltun.quic.port (one per client on a gateway; see its description)";
      }
      {
        assertion = !cfg.quic.enable || cfg.jumps == [ ] || cfg.quic.host != null;
        message = "my.globaltun.quic: the gateway sits behind ssh jumps, which cannot carry UDP; set my.globaltun.quic.host to an address this machine reaches directly";
      }
      {
        assertion = !cfg.pinAccessPoint || config.networking.networkmanager.enable;
        message = "my.globaltun.pinAccessPoint requires networking.networkmanager.enable (the pin is a NetworkManager BSSID)";
      }
      {
        assertion = !cfg.auto.enable || cfg.auto.ssids != [ ];
        message = "my.globaltun.auto.enable requires at least one my.globaltun.auto.ssids entry";
      }
      {
        assertion = !cfg.auto.enable || config.networking.networkmanager.enable;
        message = "my.globaltun.auto.enable requires networking.networkmanager.enable (the SSID is read with nmcli)";
      }
    ] ++ hopAssertions;

    systemd.services.globaltun-auto = lib.mkIf cfg.auto.enable {
      description = "Decide whether the globaltun tunnel should be up";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe autoScript;
      };
    };

    systemd.timers.globaltun-auto = lib.mkIf cfg.auto.enable {
      description = "Periodic globaltun uplink check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = cfg.auto.interval;
        AccuracySec = "10s";
      };
    };

    systemd.services.globaltun-schedule = lib.mkIf cfg.schedule.enable {
      description = "Keep the globaltun tunnel up for the nightly window";
      # No network ordering: without an active scheduled SSID the script does
      # nothing, and the next tick (5 minutes) looks again.
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe scheduleScript;
      };
    };

    systemd.timers.globaltun-schedule = lib.mkIf cfg.schedule.enable {
      description = "globaltun nightly window (${cfg.schedule.up}-${cfg.schedule.down})";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # The two edges exactly, every 5 minutes for a machine that was asleep
        # or off the SSIDs at the edge, and once after boot.
        OnCalendar = [ "*-*-* ${cfg.schedule.up}:00" "*-*-* ${cfg.schedule.down}:00" "*:0/5" ];
        OnBootSec = "2min";
        AccuracySec = "10s";
      };
    };

    /*
      --no-block matters: dispatcher scripts run synchronously inside
      NetworkManager, and bring-up can take minutes on a slow proot login.
      Blocking here would stall NM's own event processing.
    */
    networking.networkmanager.dispatcherScripts = lib.mkIf cfg.auto.enable [{
      type = "basic";
      source = pkgs.writeShellScript "globaltun-dispatch" ''
        case "$2" in
          up|down|connectivity-change) systemctl start --no-block globaltun-auto.service ;;
        esac
      '';
    }];
  };
}
