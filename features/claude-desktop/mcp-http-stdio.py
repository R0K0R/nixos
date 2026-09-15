"""Speak MCP over stdin/stdout to a server that speaks it over HTTP.

Claude Desktop's config file takes `command`/`args`/`env` and nothing else --
its own schema is

    { command: string, args?: string[], env?: Record<string,string>,
      extensionId?: string }

so an entry with `type` and `url` is rejected outright ("not valid MCP server
configurations and were skipped").  The HTTP transports in the app are for
connectors configured against the account, not for this file.

The two framings are the same JSON-RPC either way: a line in, a line out.
So this reads a message per line, posts it, and prints whatever comes back.
A notification gets no reply and is answered with 202 and an empty body, in
which case nothing is printed -- printing an empty line there would break the
framing for the message after it.
"""

import json
import sys
import urllib.error
import urllib.request


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: mcp-http-stdio <url>", file=sys.stderr)
        return 2
    url = sys.argv[1]

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError as e:
            print(f"mcp-http-stdio: unparsable line: {e}", file=sys.stderr)
            continue

        req = urllib.request.Request(
            url,
            data=line.encode("utf-8"),
            headers={"Content-Type": "application/json",
                     "Accept": "application/json, text/event-stream"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                body = resp.read().decode("utf-8").strip()
                if resp.status == 202 or not body:
                    continue
                sys.stdout.write(body + "\n")
                sys.stdout.flush()
        except Exception as e:
            # A request is owed an answer even when the server cannot be
            # reached: without one the client waits for a reply that is never
            # coming.  A notification is owed nothing, so it says nothing.
            mid = msg.get("id") if isinstance(msg, dict) else None
            print(f"mcp-http-stdio: {type(e).__name__}: {e}", file=sys.stderr)
            if mid is not None:
                sys.stdout.write(json.dumps({
                    "jsonrpc": "2.0", "id": mid,
                    "error": {"code": -32000, "message": f"{type(e).__name__}: {e}"},
                }) + "\n")
                sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
