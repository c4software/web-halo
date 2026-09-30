#!/usr/bin/env python3
"""Point the built page at the local signaling service.

Empties the signaling URL (the client then uses http://<loopback>:8787, see
apiBase() in port/web/online_client.js) and the Turnstile site key, and drops
the Turnstile script, so the page contacts no Cloudflare service. The link
step minifies the HTML, so attributes are matched in any order and quoting.
"""

import re
import sys
from pathlib import Path

page = Path(sys.argv[1] if len(sys.argv) > 1 else "build/web/halo.html")
html = page.read_text(encoding="utf-8")

for name in ("halo-signaling-url", "halo-turnstile-sitekey"):
    html, count = re.subn(
        r"<meta\b(?=[^>]*\bname=\"?%s\"?[\s>])[^>]*>" % re.escape(name),
        '<meta name="%s" content="">' % name,
        html,
    )
    if count != 1:
        sys.exit(f"localize_page.py: expected one <meta name={name}>, found {count}")

html = re.sub(
    r"<script\b[^>]*challenges\.cloudflare\.com/turnstile[^>]*>\s*</script>", "", html
)
page.write_text(html, encoding="utf-8")
print(f"{page}: local signaling, no Turnstile")
