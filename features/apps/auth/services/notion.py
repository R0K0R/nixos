"""auth notion: call the Notion API with the planner's integration token, which only this program can read.

  auth notion METHOD PATH [--version V]     the JSON body, if any, on stdin

Runs as the `auth` system user through one sudo rule (see ../nixos.nix). The caller never sees the token: it
gets the API's JSON response and nothing else. What it can reach is limited to what the token can: the pages
the user shared with the integration in Notion (••• → Connections).

Narrow on purpose:
  - only https://api.notion.com, only paths under /v1/ made of URL-safe characters, so a caller cannot point the
    token at another host or smuggle a second request;
  - GET, POST and PATCH (Notion deletes by PATCHing `in_trash`/`archived`);
  - bodies up to 1 MB of JSON; a 60 s timeout.
Exit 0 with the response on a 2xx; exit 1 with {"error", "status", "body"} otherwise.
"""
import json
import re
import sys
import urllib.error
import urllib.request

CRED_FILE = "@credFile@"
API = "https://api.notion.com"
DEFAULT_VERSION = "2022-06-28"
PATH_RE = re.compile(r"^/v1/[A-Za-z0-9/_\-]*(\?[A-Za-z0-9_\-=&%.]*)?$")
METHODS = ("GET", "POST", "PATCH")


def fail(msg, status=None, body=None):
    print(json.dumps({"error": msg, "status": status, "body": body}, ensure_ascii=False))
    sys.exit(1)


def token():
    try:
        for line in open(CRED_FILE, encoding="utf-8"):
            k, _, v = line.strip().partition("=")
            if k == "NOTION_TOKEN" and v.strip():
                return v.strip()
    except OSError:
        fail("the Notion credentials are not readable (is the auth feature switched on?)")
    fail("NOTION_TOKEN is missing from the credentials file")


def main(argv):
    args = list(argv)
    version = DEFAULT_VERSION
    if "--version" in args:
        i = args.index("--version")
        if i + 1 >= len(args) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args[i + 1]):
            fail("--version takes a date like 2022-06-28")
        version = args[i + 1]
        del args[i:i + 2]
    if len(args) != 2:
        fail("usage: auth notion METHOD PATH [--version V]  (JSON body on stdin)")
    method, path = args[0].upper(), args[1]
    if method not in METHODS:
        fail(f"method must be one of {', '.join(METHODS)}")
    if not PATH_RE.match(path):
        fail("path must look like /v1/... (URL-safe characters only)")
    data = None
    if method != "GET":
        raw = sys.stdin.buffer.read(1_000_001)
        if len(raw) > 1_000_000:
            fail("body larger than 1 MB")
        if raw.strip():
            try:
                json.loads(raw)
            except ValueError:
                fail("the body on stdin is not JSON")
            data = raw
        else:
            data = b"{}"
    req = urllib.request.Request(API + path, data=data, method=method, headers={
        "Authorization": "Bearer " + token(), "Notion-Version": version, "Content-Type": "application/json",
        "User-Agent": "dms-planner"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            sys.stdout.write(r.read().decode("utf-8"))
            sys.stdout.write("\n")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        try:
            body = json.loads(body)
        except ValueError:
            pass
        fail(f"Notion answered {e.code}", e.code, body)
    except (urllib.error.URLError, TimeoutError) as e:
        fail(f"cannot reach Notion: {e}")


if __name__ == "__main__":
    main(sys.argv[1:])
