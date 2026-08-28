#!/usr/bin/env python3
"""Scrape the latest Office Deployment Tool (ODT) download URL from Microsoft.

The Microsoft Download Center page is bot-protected for plain HTTP clients,
so we render it with a headless browser (Playwright) and extract the direct
download.microsoft.com link. The result is written to tools/odt-url.txt.
"""
import re
import sys
from playwright.sync_api import sync_playwright

PAGE_URL = "https://www.microsoft.com/en-us/download/details.aspx?id=49117"
OUT_FILE = "tools/odt-url.txt"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")


def main() -> int:
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page(user_agent=UA)
        page.goto(PAGE_URL, wait_until="networkidle", timeout=90000)
        page.wait_for_timeout(3000)  # let any lazy-loaded links render
        html = page.content()
        browser.close()

    # Prefer the ODT-specific filename, then any download.microsoft.com .exe
    patterns = [
        r'https://download\.microsoft\.com/[^"\'<>\s]*officedeploymenttool[^"\'<>\s]*\.exe',
        r'https://download\.microsoft\.com/[^"\'<>\s]*\.exe',
    ]
    for pat in patterns:
        m = re.search(pat, html)
        if m:
            url = m.group(0)
            with open(OUT_FILE, "w") as f:
                f.write(url + "\n")
            print(f"OK: {url}")
            return 0

    print("ERROR: could not find ODT download URL in page", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())