#!/usr/bin/env python3
"""Scrape the latest Office Deployment Tool (ODT) download URL from Microsoft.

Uses Camoufox (a stealth Firefox build) to render the bot-protected Microsoft
Download Center page and extract the direct download.microsoft.com link.
Writes the result to tools/odt-url.txt.
"""
import re
import sys
from camoufox.sync_api import Camoufox

PAGE_URL = "https://www.microsoft.com/en-us/download/details.aspx?id=49117"
OUT_FILE = "tools/odt-url.txt"

URL_RE = re.compile(
    r'https://download\.microsoft\.com/[^"\'<>\s]*officedeploymenttool[^"\'<>\s]*\.exe'
)


def main() -> int:
    with Camoufox(headless=True) as browser:
        page = browser.new_page()

        found = {"url": None}

        def on_response(response):
            if found["url"]:
                return
            try:
                body = response.text()
            except Exception:
                return
            m = URL_RE.search(body)
            if m:
                found["url"] = m.group(0)

        page.on("response", on_response)

        page.goto(PAGE_URL, wait_until="domcontentloaded", timeout=90000)
        page.wait_for_timeout(8000)  # let lazy-loaded content render

        print(f"DEBUG: title={page.title()!r}", file=sys.stderr)

        # 1) Rendered HTML
        url = None
        m = URL_RE.search(page.content())
        if m:
            url = m.group(0)

        # 2) Click the Download link and capture the download URL
        if not url:
            try:
                with page.expect_download(timeout=20000) as dl_info:
                    page.get_by_role("link", name="Download").first.click()
                url = dl_info.value.url
                print(f"DEBUG: captured download url={url}", file=sys.stderr)
            except Exception as e:
                print(f"DEBUG: download click failed: {e}", file=sys.stderr)

        # 3) Network responses
        if not url:
            url = found["url"]

    if not url:
        print("ERROR: could not find ODT download URL in page", file=sys.stderr)
        return 1

    with open(OUT_FILE, "w") as f:
        f.write(url + "\n")
    print(f"OK: {url}")
    return 0


if __name__ == "__main__":
    sys.exit(main())