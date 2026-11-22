#!/usr/bin/env python3
"""Checks every link in the docs and the website. CI runs it in the Demo workflow.

    python3 docs/check-links.py [--offline]

Relative links must point at a file in the repository, and a #fragment at a heading in
that Markdown file (GitHub's anchor rules) or an id in that HTML file. Files the Pages
workflow copies into site/ count as present. Web links are fetched with curl and must not
answer 404 or 410, or fail to connect. Other errors (403, 429, 5xx) only warn: some sites
turn away scripts, and a check that fails on their mood would get ignored.

--offline skips the web links.
"""
import glob
import html
import os
import re
import subprocess
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = (
    ["README.md", "CONTRIBUTING.md", "SECURITY.md", "CODE_OF_CONDUCT.md", "packaging/homebrew/README.md",
     "site/index.html"]
    + sorted(glob.glob("docs/*.md", root_dir=ROOT))
    + sorted(glob.glob(".github/ISSUE_TEMPLATE/*.yml", root_dir=ROOT))
)
# Links not to check.
IGNORE = set()
URL = re.compile(r"""https?://[^\s<>"'`)\]]+""")
MD_LINK = re.compile(r"\]\(([^)\s]+)\)")
HTML_LINK = re.compile(r"""(?:href|src)="([^"]+)\"""")


def slug(heading):
    """GitHub's anchor for a Markdown heading."""
    text = re.sub(r"<[^>]+>", "", heading).strip().lower()
    text = re.sub(r"[`*_]", "", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    kept = "".join(c for c in text if c in " -" or unicodedata.category(c)[0] in "LN")
    return kept.replace(" ", "-")


def anchors(path):
    text = open(path, encoding="utf-8").read()
    if path.endswith(".html"):
        return set(re.findall(r'id="([^"]+)"', text))
    found, seen = set(), {}
    in_code = False
    for line in text.splitlines():
        if line.lstrip().startswith(("```", "~~~")):
            in_code = not in_code
            continue
        m = re.match(r"#{1,6}\s+(.*?)\s*#*\s*$", line)
        if m and not in_code:
            s = slug(m.group(1))
            n = seen.get(s, 0)
            seen[s] = n + 1
            found.add(s if n == 0 else f"{s}-{n}")
    return found


def copied_into_site():
    """Files .github/workflows/pages.yml copies into site/ before it deploys."""
    text = open(os.path.join(ROOT, ".github/workflows/pages.yml"), encoding="utf-8").read()
    return {os.path.normpath(p) for p in re.findall(r"\bsite/[\w.-]+", text)}


def links(path):
    text = open(os.path.join(ROOT, path), encoding="utf-8").read()
    found = set(URL.findall(text))
    if path.endswith(".md"):
        found |= set(MD_LINK.findall(text))
        found |= set(HTML_LINK.findall(text))
    elif path.endswith(".html"):
        found |= {html.unescape(u) for u in HTML_LINK.findall(text)}
    return {u.rstrip(".,;:") for u in found}


def check_local(source, link, site_files):
    target, _, fragment = link.partition("#")
    base = os.path.dirname(source)
    rel = os.path.normpath(os.path.join(base, target)) if target else source
    path = os.path.join(ROOT, rel)
    if not os.path.exists(path) and rel not in site_files:
        return f"no file {rel}"
    if fragment and os.path.isfile(path) and rel.endswith((".md", ".html")):
        if fragment not in anchors(path):
            return f"no heading #{fragment} in {rel}"
    return None


def fetch(url):
    """HTTP status after redirects, or 0 when curl could not connect."""
    for method in (["--head"], ["--range", "0-0"]):
        r = subprocess.run(
            ["curl", "-sSL", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "30", "--retry", "2",
             "--retry-all-errors", "-A", "Mozilla/5.0 (link check)", *method, url],
            capture_output=True, text=True)
        code = int(r.stdout or 0)
        # Some servers refuse HEAD; ask again with a one-byte GET.
        if code not in (0, 403, 404, 405, 501):
            return code
    return code


def main():
    offline = "--offline" in sys.argv
    site_files = copied_into_site()
    errors, warnings, web = [], [], {}
    for path in FILES:
        if not os.path.exists(os.path.join(ROOT, path)):
            errors.append(f"{path}: listed in check-links.py but missing")
            continue
        for link in sorted(links(path)):
            if link.startswith(("mailto:", "data:")) or link in IGNORE:
                continue
            if link.startswith(("http://", "https://")):
                web.setdefault(link, []).append(path)
                continue
            problem = check_local(path, link, site_files)
            if problem:
                errors.append(f"{path}: {link}: {problem}")
    if not offline:
        for url, sources in sorted(web.items()):
            code = fetch(url)
            line = f"{', '.join(sorted(set(sources)))}: {url}: HTTP {code or 'no connection'}"
            if code in (0, 404, 410):
                errors.append(line)
            elif code >= 400:
                warnings.append(line)
            else:
                print(f"ok {code} {url}")
    for w in warnings:
        print(f"::warning::{w}")
    for e in errors:
        print(f"::error::{e}")
    print(f"check-links: {len(FILES)} files, {len(web)} web links, {len(errors)} broken, {len(warnings)} warnings")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
