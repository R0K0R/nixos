"""copykiller-login: log in to ksa.copykiller.com and print the session cookies.

Runs as the copykiller-auth system user (via the sudo rule in nixos.nix), the
only account that can read the credentials file. The caller gets cookies and
never the credentials.

Hardened against a caller who controls argv and the environment:
  - no arguments are honoured except the fixed subcommand `login`, so the
    target host cannot be redirected to capture the password;
  - the URL, credentials path and CA bundle are substituted at build time;
  - TLS verification uses that pinned CA bundle, never env (SSL_CERT_FILE etc.);
  - the credentials file is parsed as KEY=VALUE lines, never sourced or eval'd;
  - output is cookies (JSON) on success, the site's own error text on failure.
"""
import http.cookiejar
import json
import re
import ssl
import sys
import urllib.parse
import urllib.request

BASE = "https://ksa.copykiller.com"
CREDS = "@credentials@"
CAFILE = "@cafile@"
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36"


def die(msg: str, code: int = 1) -> None:
    sys.stderr.write("copykiller-login: " + msg + "\n")
    sys.exit(code)


def read_creds() -> tuple[str, str]:
    vals = {}
    try:
        with open(CREDS, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    vals[k.strip()] = v.strip().strip('"').strip("'")
    except OSError as e:
        die(f"cannot read credentials ({e.strerror})")
    uid, pw = vals.get("COPYKILLER_ID"), vals.get("COPYKILLER_PW")
    if not uid or not pw:
        die("credentials file lacks COPYKILLER_ID / COPYKILLER_PW")
    return uid, pw


def main() -> None:
    if sys.argv[1:] not in ([], ["login"]):
        die("usage: copykiller-login [login]", 2)
    uid, pw = read_creds()

    jar = http.cookiejar.CookieJar()
    ctx = ssl.create_default_context(cafile=CAFILE)
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),  # explicit empty: never take proxies from env
        urllib.request.HTTPSHandler(context=ctx),
        urllib.request.HTTPCookieProcessor(jar),
    )

    def req(path, data=None, json_reply=False):
        headers = {"User-Agent": UA, "Referer": BASE + "/"}
        body = None
        if data is not None:
            body = urllib.parse.urlencode(data).encode()
            headers["Content-Type"] = "application/json" if json_reply else "application/x-www-form-urlencoded"
            headers["X-Requested-With"] = "XMLHttpRequest"
        with opener.open(urllib.request.Request(BASE + path, data=body, headers=headers), timeout=30) as r:
            return r.read().decode("utf-8", "replace")

    try:
        req("/")
        raw = req("/", {
            "error_return_url": "/", "mid": "welcome", "vid": "",
            "module": "member", "act": "procMemberLogin",
            "success_return_url": "/", "user_id": uid, "password": pw,
        }, json_reply=True)
    except Exception as e:
        die(f"request failed: {type(e).__name__}")
    del pw

    try:
        j = json.loads(raw)
    except ValueError:
        die("unexpected (non-JSON) login response")
    if str(j.get("error", 0)) not in ("0", ""):
        msg = re.sub(r"<[^>]+>", " ", str(j.get("message", "")))
        die("login rejected: " + re.sub(r"\s+", " ", msg).strip())

    cookies = [
        {"name": c.name, "value": c.value, "domain": c.domain, "path": c.path}
        for c in jar
        if c.domain.lstrip(".").endswith("copykiller.com")
    ]
    if not cookies:
        die("login returned no session cookie")
    json.dump({"cookies": cookies}, sys.stdout)
    sys.stdout.write("\n")


main()
