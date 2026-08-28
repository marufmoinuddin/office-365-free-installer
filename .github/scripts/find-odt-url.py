#!/usr/bin/env python3
"""Find the latest Office Deployment Tool (ODT) download URL via GitHub code search.

Fallback for scrape-odt.py. Uses the GitHub code search API (with GITHUB_TOKEN)
to find the newest officedeploymenttool_*.exe URL referenced anywhere in public
GitHub code, and writes it to tools/odt-url.txt.
"""
import json
import os
import re
import sys
import urllib.parse
import urllib.request

OUT_FILE = "tools/odt-url.txt"
TOKEN = os.environ.get("GITHUB_TOKEN", "")

URL_RE = re.compile(
    r'https://download\.microsoft\.com/[^"\'<>\s]*officedeploymenttool_(\d+)-(\d+)\.exe'
)


def api(url: str) -> dict:
    req = urllib.request.Request(url)
    req.add_header("Accept", "application/vnd.github.text-match+json")
    req.add_header("User-Agent", "office-365-free-installer")
    if TOKEN:
        req.add_header("Authorization", f"Bearer {TOKEN}")
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


def main() -> int:
    query = "officedeploymenttool_ in:file"
    url = ("https://api.github.com/search/code?q="
           + urllib.parse.quote(query) + "&per_page=100")
    data = api(url)

    best = None  # (version_tuple, url)
    for item in data.get("items", []):
        for match in item.get("text_matches", []):
            for m in URL_RE.finditer(match.get("fragment", "")):
                ver = (int(m.group(1)), int(m.group(2)))
                if best is None or ver > best[0]:
                    best = (ver, m.group(0))

    if not best:
        print("ERROR: no ODT URL found via GitHub code search", file=sys.stderr)
        return 1

    url = best[1]
    with open(OUT_FILE, "w") as f:
        f.write(url + "\n")
    print(f"OK: {url}")
    return 0


if __name__ == "__main__":
    sys.exit(main())