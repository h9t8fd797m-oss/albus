#!/usr/bin/env python3
"""Fetch each tool's real logo, once, at build time.

A tool shows its real mark or it shows nothing. It never shows a colour this app
invented for it — see the note in StudyTool.swift.

Why build time and not runtime: fetching favicons when the Tools tab opens would
tell two hundred companies when a student opened it, cost a request per tile, and
leave the screen broken offline. This runs on a developer's machine, the results
are committed, and the app makes no network call to show a logo.

What it takes: an `apple-touch-icon` where the site declares one, since that is
the mark a brand chose for a small square on a phone — exactly this use. Falls
back to a declared `icon`, then to the well-known paths. Anything under 64px, or
that is not a real raster image, is dropped rather than shipped blurry.

Usage:
    python3 fetch_logos.py            # fetch into ./logos
    python3 fetch_logos.py --report   # just say what is missing
"""

import concurrent.futures
import html
import importlib.util
import pathlib
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

HERE = pathlib.Path(__file__).parent
OUT = HERE / "logos"

# Identifies the client honestly. A blank or forged user agent is how you get
# blocked, and pretending to be a browser to fetch a public favicon is a lie
# with no upside.
UA = "AlbusLogoFetcher/1.0 (+https://github.com/h9t8fd797m-oss/albus) build-time asset fetch"

MIN_SIDE = 64
TIMEOUT = 12


def load_tools():
    spec = importlib.util.spec_from_file_location("gen", HERE / "gen.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.T


def ident(name: str) -> str:
    s = re.sub(r"[^A-Za-z0-9]+", " ", name).title().replace(" ", "")
    s = s[0].lower() + s[1:]
    if s[0].isdigit():
        s = "t" + s
    return s


def get(url: str, limit: int = 3_000_000) -> tuple[bytes, str] | None:
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": UA,
            "Accept": "text/html,image/png,image/*;q=0.9,*/*;q=0.5",
        })
        with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
            return response.read(limit), response.geturl()
    except Exception:
        return None


LINK_RE = re.compile(r"<link\b[^>]*>", re.I)
REL_RE = re.compile(r'rel\s*=\s*["\']?([^"\'>]+)', re.I)
HREF_RE = re.compile(r'href\s*=\s*["\']([^"\']+)', re.I)
SIZES_RE = re.compile(r'sizes\s*=\s*["\']?(\d+)x(\d+)', re.I)


def candidates(host: str) -> list[str]:
    """Icon URLs for a host, best first."""
    found: list[tuple[int, str]] = []
    page = get(f"https://{host}/", limit=400_000)
    if not page and not host.startswith("www."):
        page = get(f"https://www.{host}/", limit=400_000)

    if page:
        body, final_url = page
        text = body.decode("utf-8", "ignore")
        for tag in LINK_RE.findall(text):
            rel = REL_RE.search(tag)
            href = HREF_RE.search(tag)
            if not rel or not href:
                continue
            rels = rel.group(1).lower().split()
            if not any(r in ("apple-touch-icon", "apple-touch-icon-precomposed", "icon",
                             "shortcut") for r in rels):
                continue

            size = 0
            if m := SIZES_RE.search(tag):
                size = min(int(m.group(1)), int(m.group(2)))
            # An apple-touch-icon is the mark chosen for a phone-sized square,
            # which is precisely what a tool tile is. Rank it above a favicon
            # even when the favicon claims a larger size.
            if "apple-touch-icon" in rels or "apple-touch-icon-precomposed" in rels:
                size += 1000

            url = html.unescape(href.group(1)).strip()
            found.append((size, urllib.parse.urljoin(final_url, url)))

    found.sort(key=lambda pair: -pair[0])
    urls = [url for _, url in found]

    for path in ("/apple-touch-icon.png", "/apple-touch-icon-precomposed.png"):
        urls.append(f"https://{host}{path}")
        if not host.startswith("www."):
            urls.append(f"https://www.{host}{path}")

    # Last resort. Google's favicon endpoint returns the site's *own* mark as a
    # PNG, which is what makes it acceptable here — it is not a substitute logo,
    # it is the same logo fetched by something the site will answer. Needed
    # because a meaningful share of these hosts refuse a non-browser client
    # outright (Quizlet answers 403 to everything that is not a browser), and
    # the alternative is lying about the user agent to scrape them.
    #
    # Build time only. Nothing about a student ever reaches this.
    urls.append(f"https://www.google.com/s2/favicons?domain={host}&sz=128")

    seen, unique = set(), []
    for url in urls:
        if url not in seen:
            seen.add(url)
            unique.append(url)
    return unique[:9]


def usable(path: pathlib.Path) -> tuple[int, int] | None:
    """Dimensions if this is a raster image big enough to ship."""
    try:
        out = subprocess.run(
            ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
            capture_output=True, text=True, timeout=20,
        ).stdout
        width = int(re.search(r"pixelWidth:\s*(\d+)", out).group(1))
        height = int(re.search(r"pixelHeight:\s*(\d+)", out).group(1))
    except Exception:
        return None
    if min(width, height) < MIN_SIDE:
        return None
    return width, height


def fetch_one(tool) -> tuple[str, str, str]:
    name, host = tool[0], tool[1]
    key = ident(name)
    target = OUT / f"{key}.png"
    if target.exists():
        return key, host, "kept"

    for url in candidates(host):
        got = get(url)
        if not got or len(got[0]) < 200:
            continue
        target.write_bytes(got[0])

        # Normalise to PNG. An SVG or an ICO will simply fail here, which is the
        # intended outcome: the app renders bundled artwork as-is, so anything
        # it cannot draw must not be bundled.
        subprocess.run(["sips", "-s", "format", "png", str(target), "--out", str(target)],
                       capture_output=True, timeout=20)

        size = usable(target)
        if size:
            # Cap the long edge. A 1024px logo in a 34pt tile is a megabyte of
            # app for pixels nobody sees.
            if max(size) > 256:
                subprocess.run(["sips", "-Z", "256", str(target)],
                               capture_output=True, timeout=20)
            return key, host, "fetched"
        target.unlink(missing_ok=True)

    return key, host, "missing"


def main() -> int:
    tools = load_tools()
    OUT.mkdir(exist_ok=True)

    if "--report" in sys.argv:
        have = {p.stem for p in OUT.glob("*.png")}
        missing = [t[0] for t in tools if ident(t[0]) not in have]
        print(f"{len(have)}/{len(tools)} logos present")
        if missing:
            print("missing:", ", ".join(sorted(missing)))
        return 0

    results = {"fetched": 0, "kept": 0, "missing": []}
    # Eight at a time: enough to finish in a couple of minutes, few enough to be
    # a polite client to two hundred unrelated servers.
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        for key, host, status in pool.map(fetch_one, tools):
            if status == "missing":
                results["missing"].append(f"{key} ({host})")
            else:
                results[status] += 1

    print(f"fetched {results['fetched']}, kept {results['kept']}, "
          f"missing {len(results['missing'])} of {len(tools)}")
    if results["missing"]:
        print("\nno usable logo — these ship with no mark at all:")
        for item in sorted(results["missing"]):
            print("  ", item)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
