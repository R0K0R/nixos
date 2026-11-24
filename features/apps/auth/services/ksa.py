"""
auth ksa: log in to ksain.kr and my.ksa.hs.kr with credentials the CALLER
cannot read, and hand back only the resulting session.

Runs as the `auth` system user through one sudo rule (see nixos.nix); the
credentials file is that user's, 0400. Everything here exists to keep the
password from leaving this process, so:

  - the site URLs are fixed: no argument names a host, path or file, so a
    caller cannot point the password at a server of its choosing;
  - TLS is verified and proxies are ignored (sudo's env_reset strips the
    variables already; the empty ProxyHandler makes that independent of it);
  - only tokens and cookies are printed, as one JSON object on stdout, and
    error messages never include the request body.

Subcommands:
  ksain                              -> {"token": ..., "requirePasswordChange": ...}
  myksa-start                        -> {"status": "ok", "cookies": {...}}
                                     or {"status": "cert", "jsessionid", "idx", "sent", "total"}
  myksa-finish <jsessionid> <idx> <code>
                                     -> {"status": "ok", "cookies": {...}}

my.ksa texts a code on a login it does not trust; the caller reads it (from
the phone, over KDE Connect -- this user cannot reach the session bus) and
passes it to myksa-finish, which redoes the credential half of the exchange.
"""

import http.cookiejar
import json
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

CRED_FILE = "@credFile@"

KSAIN_API = "https://api.ksain.kr"
MYKSA = "https://my.ksa.hs.kr"
MYKSA_DOMAIN = "my.ksa.hs.kr"
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"


def die(msg, code=1):
    print(json.dumps({"status": "error", "error": msg}, ensure_ascii=False))
    sys.exit(code)


def load_creds():
    """KEY=value lines; '#' comments. Parsed, never sourced."""
    creds = {}
    try:
        with open(CRED_FILE, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\r\n")
                if not line.strip() or line.lstrip().startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                creds[k.strip()] = v
    except OSError as e:
        die(f"cannot read credentials ({e.strerror})")
    return creds


def need(creds, *keys):
    missing = [k for k in keys if not creds.get(k)]
    if missing:
        die("credentials file lacks " + ", ".join(missing))
    return [creds[k] for k in keys]


def opener(jar=None):
    handlers = [
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()),
    ]
    if jar is not None:
        handlers.append(urllib.request.HTTPCookieProcessor(jar))
    return urllib.request.build_opener(*handlers)


def request(op, url, data=None, headers=None):
    assert url.startswith((KSAIN_API + "/", MYKSA + "/"))
    req = urllib.request.Request(url, data=data, headers={"User-Agent": UA, **(headers or {})})
    try:
        with op.open(req, timeout=20) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        die(f"network error: {getattr(e, 'reason', e)}")


def parse_json(body):
    try:
        return json.loads(body)
    except ValueError:
        return None


# --- ksain.kr ---------------------------------------------------------------

def ksain_post(path, payload):
    status, body = request(
        opener(),
        KSAIN_API + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Origin": "https://ksain.kr",
                 "Referer": "https://ksain.kr/"},
    )
    j = parse_json(body) or {}
    data = j.get("data") if isinstance(j.get("data"), dict) else {}
    return status, j, data


def ksain():
    # ksain has two logins: /auth/signin-student takes the 학번 (YY-000),
    # /auth/signin a ksain username. KSAIN_ID may be either, so the student
    # route is tried first and the username route on its 401.
    ident, pw = need(load_creds(), "KSAIN_ID", "KSAIN_PW")
    status, j, data = ksain_post("/auth/signin-student", {"positionID": ident, "password": pw})
    if status == 401:
        status, j, data = ksain_post("/auth/signin", {"uid": ident, "password": pw})
    if status != 200 or not data.get("token"):
        die(f"ksain login failed (HTTP {status}): {str(j.get('message') or j.get('error') or '')[:200]}")
    print(json.dumps({
        "status": "ok",
        "token": data["token"],
        "requirePasswordChange": bool(data.get("requirePasswordChange")),
    }))


# --- my.ksa.hs.kr -----------------------------------------------------------

def myksa_form(creds, cert=""):
    uid, pw = need(creds, "MYKSA_ID", "MYKSA_PW")
    # Field order and names as jQuery's serialize() of #login-form sends them.
    return [("loginType", "S"), ("USER_ID", uid), ("USER_PW", pw), ("USER_CERT", cert), ("login-lang", "ko")]


MYKSA_AJAX = {
    "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
    "X-Requested-With": "XMLHttpRequest",
    "Accept": "*/*",
    # Without these two the server answers HTTP 500, not a result code.
    "Origin": MYKSA,
    "Referer": MYKSA + "/jsp/login/login",
}


def myksa_cookies(jar):
    return {c.name: c.value for c in jar if c.domain.lstrip(".") == MYKSA_DOMAIN}


def myksa_process(op, jar, form):
    status, body = request(op, MYKSA + "/loginProcess", data=urllib.parse.urlencode(form).encode(),
                           headers=MYKSA_AJAX)
    j = parse_json(body)
    if status != 200 or not isinstance(j, dict) or j.get("login_flag") != "Y":
        die(f"my.ksa loginProcess refused (HTTP {status})")
    print(json.dumps({"status": "ok", "cookies": myksa_cookies(jar)}))


def myksa_start():
    creds = load_creds()
    form = myksa_form(creds)
    jar = http.cookiejar.CookieJar()
    op = opener(jar)
    request(op, MYKSA + "/jsp/login/login")  # sets JSESSIONID
    status, body = request(op, MYKSA + "/loginCert", data=urllib.parse.urlencode(form).encode(),
                           headers=MYKSA_AJAX)
    j = parse_json(body)
    if status != 200 or not isinstance(j, dict):
        die(f"my.ksa loginCert failed (HTTP {status})")
    msg = j.get("resultMessage")
    if msg == "success":
        return myksa_process(op, jar, form)
    if msg == "cert":
        sid = myksa_cookies(jar).get("JSESSIONID")
        if not sid:
            die("my.ksa sent a code but set no JSESSIONID")
        print(json.dumps({"status": "cert", "jsessionid": sid, "idx": str(j.get("IDX", "")),
                          "sent": j.get("SEND_CNT"), "total": j.get("TOT_CNT")}))
        return
    known = {"W008": "wrong id/password", "W010": "daily verification limit reached",
             "W011": "verification error", "W012": "no phone number registered"}
    die(f"my.ksa: {known.get(msg, msg)}")


def myksa_finish(sid, idx, code):
    if not re.fullmatch(r"[A-Za-z0-9._-]{8,128}", sid):
        die("bad jsessionid")
    if not re.fullmatch(r"\d{1,20}", idx):
        die("bad idx")
    if not re.fullmatch(r"\d{4,10}", code):
        die("bad code")
    creds = load_creds()
    jar = http.cookiejar.CookieJar()
    jar.set_cookie(http.cookiejar.Cookie(
        0, "JSESSIONID", sid, None, False, MYKSA_DOMAIN, False, False, "/", True,
        True, None, False, None, None, {"HttpOnly": None}))
    op = opener(jar)
    form = myksa_form(creds, cert=code)
    status, body = request(op, MYKSA + "/loginCertChk",
                           data=(urllib.parse.urlencode(form) + "&IDX=" + idx).encode(),
                           headers=MYKSA_AJAX)
    result = body.strip().strip('"')
    if status != 200 or result != "success":
        known = {"W013": "code expired", "W014": "wrong code"}
        die(f"my.ksa: {known.get(result, 'code check failed (HTTP %d)' % status)}")
    myksa_process(op, jar, myksa_form(creds))


def main(argv):
    if argv == ["ksain"]:
        return ksain()
    if argv == ["myksa-start"]:
        return myksa_start()
    if len(argv) == 4 and argv[0] == "myksa-finish":
        return myksa_finish(*argv[1:])
    print("usage: auth ksa ksain | myksa-start | myksa-finish <jsessionid> <idx> <code>", file=sys.stderr)
    sys.exit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
