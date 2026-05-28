#!/usr/bin/env python3
"""
Recover 1024-aligned-truncated assets INSIDE a HandWriter .ncnote ZIP.

The companion `recover_truncated_assets.py` operates on the Nextcloud desktop
mirror (exploded delta files); this one targets the app's own working copy
(`~/Documents/HandWriter/notebooks/<id>.ncnote`) for the case where the
server's saved bytes are also poisoned and the only clean source left is the
original PDF.

For each asset whose size is a multiple of 1024 (the truncation fingerprint),
this script:
  1. Parses `<uuid>_<pdf>_p<N>.png` from the filename.
  2. Locates the source PDF under one or more PDF roots (--pdf-root, repeatable;
     defaults cover both the legacy `~/Nextcloud/CLOUD/My files` and the
     current `~/Nextcloud/CLOUD/Unipd`).
  3. Reads the truncated PNG's IHDR (still parseable — only the trailing IDAT
     gets cut at the 1024-boundary) to recover the original pixel width.
  4. Derives the render DPI from that width vs `pdfinfo` page-size in points.
  5. Re-renders page N with `pdftocairo` at the derived DPI and verifies the
     result is a valid PNG with an IHDR and is NOT itself 1024-aligned.
  6. With --apply, rewrites the asset bytes in-place by streaming all entries
     into a sibling temp ZIP and atomically renaming it over the original.

CRITICAL: close the app before running --apply. The app holds and rewrites
this file via its own save path; concurrent writes would race.

Usage:
  python3 tool/recover_ncnote_truncated.py PATH/notebook.ncnote          # dry-run
  python3 tool/recover_ncnote_truncated.py PATH/notebook.ncnote --apply
  python3 tool/recover_ncnote_truncated.py PATH/notebook.ncnote \
      --pdf-root ~/Nextcloud/CLOUD/Unipd --apply
"""

import argparse
import base64
import json
import os
import re
import shutil
import ssl
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

DEFAULT_PDF_ROOTS = [
    Path.home() / "Nextcloud" / "CLOUD" / "Unipd",
    Path.home() / "Nextcloud" / "CLOUD" / "My files",
]
PREFS_PATH = (Path.home() / ".local" / "share" / "com.example.handwriter"
              / "shared_preferences.json")
# Asset filename shape: <uuid>_<pdfname>.pdf_p<N>.png
ASSET_RE = re.compile(r"^[0-9a-f-]+_(?P<pdf>.+?\.pdf)_p(?P<pg>\d+)\.png$", re.I)


def load_credentials():
    """Read WebDAV creds the app uses, from its prefs file."""
    with open(PREFS_PATH) as f:
        prefs = json.load(f)
    server = prefs["flutter.nc_server_url"].rstrip("/")
    user = prefs["flutter.nc_username"]
    pw = prefs["flutter.nc_password"]
    auth = base64.b64encode(f"{user}:{pw}".encode()).decode()
    return server, user, auth


def http(method, url, auth, *, body=None, content_type=None, extra=None):
    headers = {"Authorization": f"Basic {auth}"}
    if content_type:
        headers["Content-Type"] = content_type
    if extra:
        headers.update(extra)
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=60) as r:
            return r.status, r.read(), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers or {})


def asset_url(server, user, notebook_id, asset_basename):
    """Build the WebDAV URL for an asset; encode each path segment."""
    enc = urllib.parse.quote(asset_basename, safe="")
    return (f"{server}/remote.php/dav/files/{user}"
            f"/HandWriter/_delta/{notebook_id}/assets/{enc}")


def upload_asset(server, user, auth, notebook_id, asset_basename, data,
                 max_attempts=3):
    """PUT the bytes and verify the server now holds exactly that size.
    Retries on transient failure; returns True on verified upload."""
    url = asset_url(server, user, notebook_id, asset_basename)
    for attempt in range(max_attempts):
        st, _, _ = http("PUT", url, auth, body=data,
                        content_type="application/octet-stream")
        if st in (200, 201, 204):
            # Verify with a HEAD: the saved size must match what we sent.
            hst, _, hh = http("HEAD", url, auth)
            if hst in (200, 204):
                got = hh.get("Content-Length")
                try:
                    got = int(got) if got is not None else None
                except ValueError:
                    got = None
                if got == len(data):
                    return True
                last = f"size mismatch: sent {len(data)} got {got}"
            else:
                last = f"HEAD failed: HTTP {hst}"
        else:
            last = f"PUT failed: HTTP {st}"
        if attempt < max_attempts - 1:
            time.sleep(0.4 * (2 ** attempt))
    print(f"  ! upload failed: {asset_basename} ({last})")
    return False


def png_width(blob: bytes):
    """Return PNG IHDR width if `blob` starts with a valid PNG; else None.

    Truncated PNGs still carry a valid header + IHDR (the cut is later, in
    IDAT), so this works on the un-decodable bytes.
    """
    if len(blob) < 24 or blob[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    if blob[12:16] != b"IHDR":
        return None
    return struct.unpack(">I", blob[16:20])[0]


def find_pdf(name: str, roots):
    """Locate a PDF file by exact basename anywhere under any of `roots`."""
    for r in roots:
        if not r.exists():
            continue
        for p in r.rglob(name):
            return p
    return None


def pdf_page_width_pt(pdf: Path, page: int):
    """Return the page's width in PostScript points (1/72 in), via pdfinfo."""
    out = subprocess.check_output(
        ["pdfinfo", "-f", str(page), "-l", str(page), str(pdf)],
        stderr=subprocess.DEVNULL,
        text=True,
    )
    # pdfinfo formats per-page size as: "Page    3 size:   960 x 540 pts"
    # (variable whitespace; the page number is padded). Be lenient with regex.
    per_page = re.compile(rf"^Page\s+{page}\s+size:\s*([\d.]+)\s*x", re.M)
    m = per_page.search(out)
    if m:
        return float(m.group(1))
    # Fallback: global "Page size:" line (uniform-page PDFs).
    glob = re.search(r"^Page size:\s*([\d.]+)\s*x", out, re.M)
    if glob:
        return float(glob.group(1))
    return None


def render_page(pdf: Path, page: int, want_width_px: int):
    """Re-render `pdf` page `page` at the DPI that yields `want_width_px`
    pixels wide. Returns the PNG bytes or None on failure."""
    pt = pdf_page_width_pt(pdf, page)
    if not pt:
        return None
    dpi = round(want_width_px / pt * 72)
    if dpi <= 0:
        return None
    tmp = Path(tempfile.mkdtemp(prefix="hwr_"))
    try:
        subprocess.check_call(
            [
                "pdftocairo", "-png",
                "-r", str(dpi),
                "-f", str(page), "-l", str(page),
                "-singlefile",
                str(pdf), str(tmp / "p"),
            ],
            stderr=subprocess.DEVNULL,
        )
        out = tmp / "p.png"
        if not out.exists():
            return None
        data = out.read_bytes()
        # Sanity: must be a real PNG, and not itself 1024-aligned.
        if not png_width(data):
            return None
        if len(data) % 1024 == 0:
            return None
        return data
    except subprocess.CalledProcessError:
        return None
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("ncnote", type=Path, help="path to the .ncnote ZIP")
    ap.add_argument("--apply", action="store_true",
                    help="actually rewrite the .ncnote (default: dry-run)")
    ap.add_argument("--pdf-root", type=Path, action="append",
                    help="search root for source PDFs (repeatable)")
    ap.add_argument("--upload", action="store_true",
                    help="after local rewrite, PUT the clean bytes to the "
                         "server (so other devices and the heal path no "
                         "longer see truncated copies). Requires --apply.")
    args = ap.parse_args()
    if args.upload and not args.apply:
        sys.exit("--upload requires --apply")

    roots = args.pdf_root or DEFAULT_PDF_ROOTS
    nb = args.ncnote.expanduser().resolve()
    if not nb.exists():
        sys.exit(f"not found: {nb}")
    print(f"notebook : {nb} ({nb.stat().st_size:,} B)")
    print(f"pdf roots: {[str(r) for r in roots]}")
    print()

    # 1. Enumerate candidates inside the ZIP.
    cand = []
    with zipfile.ZipFile(nb) as z:
        for info in z.infolist():
            if not info.filename.startswith("assets/"):
                continue
            if info.file_size == 0 or info.file_size % 1024 != 0:
                continue
            base = info.filename.split("/", 1)[1]
            m = ASSET_RE.match(base)
            if not m:
                print(f"  ?  {base}  (1024-aligned but unparseable name)")
                continue
            cand.append((info.filename, base, m.group("pdf"), int(m.group("pg"))))
    print(f"truncated-fingerprint assets: {len(cand)}")
    if not cand:
        print("nothing to do")
        return

    # 2. Try to re-render each.
    recovered = []  # (zip-path, new bytes)
    failed = []
    with zipfile.ZipFile(nb) as z:
        for fn, base, pdf_name, pg in cand:
            pdf = find_pdf(pdf_name, roots)
            if not pdf:
                print(f"  !  PDF not found: {pdf_name}  → for {base}")
                failed.append((base, "no-pdf"))
                continue
            blob = z.read(fn)
            w = png_width(blob)
            if not w:
                print(f"  !  no IHDR in truncated PNG: {base}")
                failed.append((base, "no-ihdr"))
                continue
            new_bytes = render_page(pdf, pg, w)
            if not new_bytes:
                print(f"  !  render failed: {pdf.name} page {pg} → {base}")
                failed.append((base, "render"))
                continue
            print(f"  ok {len(blob):>8}B → {len(new_bytes):>8}B  "
                  f"{pdf.name} p{pg}  (w={w}px)")
            recovered.append((fn, new_bytes))

    print()
    print(f"recoverable: {len(recovered)} / {len(cand)}    failed: {len(failed)}")

    if not args.apply:
        print("\n(dry-run — re-run with --apply to rewrite the .ncnote)")
        return
    if not recovered:
        print("nothing to write")
        return

    # 3. Atomic rewrite: stream all entries (replacing recovered ones) into a
    #    sibling temp ZIP, then os.replace it over the original.
    replacements = dict(recovered)
    tmp = nb.with_suffix(nb.suffix + ".recovery.tmp")
    if tmp.exists():
        tmp.unlink()
    with zipfile.ZipFile(nb, "r") as src, zipfile.ZipFile(
            tmp, "w", compression=zipfile.ZIP_DEFLATED) as dst:
        for info in src.infolist():
            data = replacements.get(info.filename)
            if data is None:
                data = src.read(info.filename)
            # Copy the entry, preserving filename + timestamps; size and CRC
            # are recomputed by writestr.
            dst.writestr(info, data)

    # 4. Verify: same set of names, all replaced entries match new bytes.
    with zipfile.ZipFile(tmp, "r") as v, zipfile.ZipFile(nb, "r") as o:
        if set(v.namelist()) != set(o.namelist()):
            tmp.unlink()
            sys.exit("ABORT: entry set changed after rewrite")
        for k, b in replacements.items():
            got = v.read(k)
            if got != b:
                tmp.unlink()
                sys.exit(f"ABORT: rewrite mismatch on {k}")

    os.replace(tmp, nb)
    print(f"\nwrote {nb}  ({len(recovered)} asset(s) replaced)")

    if not args.upload:
        print("Local-only: re-run with --upload to also push clean bytes to "
              "the server (otherwise other devices keep the truncated copy).")
        return

    # 5. Push the recovered bytes to the server too, so the saved copy in the
    #    notebook stops being poisoned for other devices / future re-syncs.
    notebook_id = nb.stem  # `<id>.ncnote` → `<id>`
    print(f"\nuploading {len(recovered)} recovered asset(s) to server...")
    try:
        server, user, auth = load_credentials()
    except (KeyError, FileNotFoundError) as e:
        print(f"  ! could not load credentials from {PREFS_PATH}: {e}")
        return
    ok = bad = 0
    for fn, data in recovered:
        base = fn.split("/", 1)[1]
        if upload_asset(server, user, auth, notebook_id, base, data):
            ok += 1
        else:
            bad += 1
    print(f"server upload: {ok} ok, {bad} failed")
    if bad == 0:
        print("Server now holds clean bytes for every recovered asset. Other "
              "devices will see clean assets on their next pull.")


if __name__ == "__main__":
    main()
