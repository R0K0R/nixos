"""phone-adb-grant: opens or closes the session grant that lets the user's processes drive the phone's adb shell.

Runs as root and does exactly three things, so there is little to get wrong:

  --grant   (only through pkexec, i.e. after the user answers a polkit prompt) write the grant for the user
            who authenticated: valid until `idle` minutes pass without use, or `max` hours pass, whichever
            is first. The user is taken from PKEXEC_UID, which pkexec sets itself.
  --revoke  remove the grant. Always allowed, without a password (a sudo rule): closing access is never risky.
  --status  show the grant.

`--grant` is deliberately NOT in the sudo rule, so the only way to it is the polkit prompt.
"""
import json
import os
import sys
import time

GRANT = "@grantFile@"
STATE = "@stateDir@"
DEFAULT_IDLE_MIN = @idleMinutes@
DEFAULT_MAX_HOURS = @maxHours@


def say(obj, code=0):
    print(json.dumps(obj, ensure_ascii=False))
    sys.exit(code)


def revoke():
    for p in (GRANT, os.path.join(STATE, "last_used")):
        try:
            os.remove(p)
        except FileNotFoundError:
            pass
    say({"granted": False})


def status():
    try:
        g = json.load(open(GRANT))
    except (OSError, ValueError):
        say({"granted": False})
    say({"granted": time.time() < g.get("max_until", 0), "uid": g.get("uid"),
         "max_left_s": int(g.get("max_until", 0) - time.time())})


def grant(idle_min, max_hours):
    uid = os.environ.get("PKEXEC_UID", "")
    if not uid.isdigit() or int(uid) == 0:
        say({"error": "refusing: a grant is only written after a polkit prompt (pkexec) for a normal user"}, 1)
    if not (1 <= idle_min <= 240 and 1 <= max_hours <= 24):
        say({"error": "idle must be 1..240 minutes and max 1..24 hours"}, 1)
    now = time.time()
    os.makedirs(os.path.dirname(GRANT), mode=0o755, exist_ok=True)
    tmp = GRANT + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    with os.fdopen(fd, "w") as f:
        json.dump({"uid": int(uid), "granted_at": now, "idle_s": idle_min * 60, "max_until": now + max_hours * 3600}, f)
    os.replace(tmp, GRANT)
    try:
        os.remove(os.path.join(STATE, "last_used"))
    except FileNotFoundError:
        pass
    say({"granted": True, "uid": int(uid), "idle_minutes": idle_min, "max_hours": max_hours})


def main(argv):
    if argv == ["--revoke"]:
        revoke()
    if argv == ["--status"]:
        status()
    if argv[:1] == ["--grant"]:
        idle, mx = DEFAULT_IDLE_MIN, DEFAULT_MAX_HOURS
        rest = argv[1:]
        try:
            while rest:
                if rest[0] == "--idle-minutes":
                    idle, rest = int(rest[1]), rest[2:]
                elif rest[0] == "--max-hours":
                    mx, rest = int(rest[1]), rest[2:]
                else:
                    raise ValueError
        except (ValueError, IndexError):
            say({"error": "usage: --grant [--idle-minutes N] [--max-hours H]"}, 1)
        grant(idle, mx)
    say({"error": "usage: --grant [...] | --revoke | --status"}, 1)


if __name__ == "__main__":
    main(sys.argv[1:])
