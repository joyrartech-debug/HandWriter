#!/usr/bin/env python3
"""
One-shot recovery for the May 2026 1024-aligned asset truncation incident.

Scans the local Nextcloud mirror for PNG assets with size % 1024 == 0
(the diagnostic signature). For each, attempts two recovery paths in
order:

  Phase A — Nextcloud Versions API:
    PROPFIND /remote.php/dav/versions/<user>/versions/<fileid>/ to find
    a historical version that is NOT 1024-aligned. If one exists, GET
    those bytes and write them in place atomically.

  Phase B — Source PDF re-render:
    Parse the asset filename `<uuid>_<pdfName>.pdf_p<N>.png` to locate
    the source PDF under ~/Nextcloud/CLOUD/My files/. Read the (still-
    parseable) PNG IHDR of the truncated file to recover the original
    pixel width, derive the DPI the app used, and re-render that page
    of the PDF with pdftocairo. Write atomically to the same asset path.

Dry-run by default. Pass --apply to actually write.

After --apply, the Nextcloud desktop client picks up the modified files
and propagates them to the server. Other devices see new ETags on the
next pull and re-download just the recovered assets.

Usage:
    python3 tool/recover_truncated_assets.py            # dry run
    python3 tool/recover_truncated_assets.py --apply    # do the writes
    python3 tool/recover_truncated_assets.py --phase A  # versions only
    python3 tool/recover_truncated_assets.py --phase B  # PDF rerender only

Credentials are read from the app's shared_preferences.json. The
password is never printed.
"""

import argparse
import base64
import json
import os
import ssl
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from http.client import IncompleteRead
from pathlib import Path
from typing import Optional

HOME = Path.home()
MIRROR_ROOT = HOME / "Nextcloud" / "HandWriter"
PDF_SEARCH_ROOT = HOME / "Nextcloud" / "CLOUD" / "My files"
PREFS_PATH = HOME / ".local" / "share" / "com.example.handwriter" / "shared_preferences.json"
NS = {"d": "DAV:", "oc": "http://owncloud.org/ns"}


@dataclass
class TruncatedAsset:
    notebook_id: str
    filename: str
    local_path: Path
    local_size: int
    pdf_name: str
    pdf_page: int
    pixel_width: Optional[int] = None
    pixel_height: Optional[int] = None
    server_fileid: Optional[str] = None
    clean_version_href: Optional[str] = None
    clean_version_size: Optional[int] = None
    pdf_source: Optional[Path] = None
    recovery_phase: Optional[str] = None  # "A" or "B" or None


def load_credentials():
    with open(PREFS_PATH) as f:
        prefs = json.load(f)
    user = prefs["flutter.nc_username"]
    pw = prefs["flutter.nc_password"]
    server = prefs["flutter.nc_server_url"].rstrip("/")
    auth = base64.b64encode(f"{user}:{pw}".encode()).decode()
    return server, user, auth


def http(method, url, auth, *, depth=None, body=None, extra_headers=None):
    headers = {"Authorization": f"Basic {auth}"}
    if depth is not None:
        headers["Depth"] = depth
    if body is not None:
        headers["Content-Type"] = "application/xml"
    if extra_headers:
        headers.update(extra_headers)
    req = urllib.request.Request(
        url,
        data=body.encode() if body else None,
        method=method,
        headers=headers,
    )
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=60) as r:
            return r.status, r.read(), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers or {})
    except IncompleteRead as e:
        # Server returned a partial body. e.partial holds what we got.
        return -2, e.partial, {}


def http_get_full(url, auth, expected_size=None, max_attempts=4):
    """Robust GET. Detects truncation against Content-Length; on failure
    falls back to Range-based chunked download (Nextcloud serves these
    even when the full-body stream cuts). Returns the assembled bytes
    or raises RuntimeError."""
    last_err = None
    for attempt in range(max_attempts):
        st, body, hdrs = http("GET", url, auth)
        if st == 200:
            declared = hdrs.get("Content-Length")
            try:
                declared = int(declared) if declared else None
            except ValueError:
                declared = None
            target = expected_size or declared
            if target is None or len(body) == target:
                return body
            last_err = f"got {len(body)}B, expected {target}B"
        elif st == -2:
            last_err = f"IncompleteRead, got {len(body)}B"
        else:
            last_err = f"HTTP {st}"
        time.sleep(0.4 * (2 ** attempt))
    # Range-based fallback: only useful if we know expected_size.
    if expected_size is None:
        raise RuntimeError(f"GET failed after {max_attempts} attempts: {last_err}")
    chunk = 256 * 1024
    out = bytearray()
    while len(out) < expected_size:
        end = min(len(out) + chunk - 1, expected_size - 1)
        for attempt in range(3):
            st, body, _ = http(
                "GET", url, auth,
                extra_headers={"Range": f"bytes={len(out)}-{end}"},
            )
            if st in (200, 206) and len(body) == end - len(out) + 1:
                out.extend(body)
                break
            if attempt == 2:
                raise RuntimeError(
                    f"Range GET stalled at offset {len(out)}/{expected_size}: HTTP {st}, {len(body)}B"
                )
            time.sleep(0.4 * (2 ** attempt))
    return bytes(out)


PROPFIND_PROPS = """<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:prop>
    <oc:fileid/>
    <d:getcontentlength/>
    <d:getlastmodified/>
  </d:prop>
</d:propfind>"""


def read_png_ihdr(path: Path):
    """Return (width, height) from the IHDR chunk — works even for
    body-truncated PNGs as long as the header survived."""
    with open(path, "rb") as f:
        sig = f.read(8)
        if sig != b"\x89PNG\r\n\x1a\n":
            return None, None
        # IHDR length(4) + type(4) + data(13) + crc(4)
        f.read(4)  # length
        chunk_type = f.read(4)
        if chunk_type != b"IHDR":
            return None, None
        width = struct.unpack(">I", f.read(4))[0]
        height = struct.unpack(">I", f.read(4))[0]
        return width, height


def scan_truncated(root: Path) -> list[TruncatedAsset]:
    out = []
    delta = root / "_delta"
    if not delta.exists():
        sys.exit(f"Delta dir not found: {delta}")
    for p in delta.rglob("*.png"):
        try:
            sz = p.stat().st_size
        except OSError:
            continue
        if sz == 0 or sz % 1024 != 0:
            continue
        # Path: _delta/<notebookId>/assets/<file>
        parts = p.relative_to(delta).parts
        if len(parts) < 3 or parts[1] != "assets":
            continue
        notebook_id = parts[0]
        filename = parts[-1]
        # Filename: <uuid>_<pdfName>.pdf_p<N>.png
        if ".pdf_p" not in filename or not filename.endswith(".png"):
            continue
        try:
            uuid_end = filename.index("_") + 1
            rest = filename[uuid_end:]
            pdf_marker = rest.rindex(".pdf_p")
            pdf_name = rest[:pdf_marker] + ".pdf"
            page_part = rest[pdf_marker + len(".pdf_p"):-4]  # strip .png
            page_num = int(page_part)
        except (ValueError, IndexError):
            continue
        w, h = read_png_ihdr(p)
        out.append(TruncatedAsset(
            notebook_id=notebook_id,
            filename=filename,
            local_path=p,
            local_size=sz,
            pdf_name=pdf_name,
            pdf_page=page_num,
            pixel_width=w,
            pixel_height=h,
        ))
    return out


def find_source_pdf(name: str) -> Optional[Path]:
    if not PDF_SEARCH_ROOT.exists():
        return None
    # Recursive glob, case-insensitive name match.
    matches = list(PDF_SEARCH_ROOT.rglob(name))
    if matches:
        return matches[0]
    return None


def query_clean_version(server, user, auth, asset: TruncatedAsset):
    quoted = urllib.parse.quote(asset.filename)
    remote = (
        f"{server}/remote.php/dav/files/{user}/HandWriter/_delta/"
        f"{asset.notebook_id}/assets/{quoted}"
    )
    st, body, _ = http("PROPFIND", remote, auth, depth="0", body=PROPFIND_PROPS)
    if st != 207:
        return
    root = ET.fromstring(body)
    fid_el = root.find(".//oc:fileid", NS)
    if fid_el is None or not fid_el.text:
        return
    asset.server_fileid = fid_el.text
    versions_url = f"{server}/remote.php/dav/versions/{user}/versions/{fid_el.text}/"
    st, body, _ = http("PROPFIND", versions_url, auth, depth="1", body=PROPFIND_PROPS)
    if st != 207:
        return
    vroot = ET.fromstring(body)
    best = None
    for resp in vroot.findall("d:response", NS):
        href = resp.find("d:href", NS)
        csz = resp.find(".//d:getcontentlength", NS)
        if href is None or csz is None or not csz.text:
            continue
        sz = int(csz.text)
        if sz <= 0 or sz % 1024 == 0:
            continue
        # Pick the LARGEST clean version (most-complete render).
        if best is None or sz > best[1]:
            best = (href.text, sz)
    if best:
        asset.clean_version_href = best[0]
        asset.clean_version_size = best[1]


def atomic_write(target: Path, data: bytes):
    tmp = target.with_suffix(target.suffix + ".tmp.recover")
    tmp.write_bytes(data)
    tmp.replace(target)


def recover_phase_a(server, user, auth, asset: TruncatedAsset, apply: bool) -> bool:
    if not asset.clean_version_href:
        return False
    version_url = f"{server}{asset.clean_version_href}"
    try:
        body = http_get_full(version_url, auth,
                             expected_size=asset.clean_version_size)
    except RuntimeError as e:
        print(f"  ✗ Versions GET failed for {asset.filename}: {e}")
        return False
    if len(body) != asset.clean_version_size:
        print(
            f"  ✗ Short GET {len(body)}/{asset.clean_version_size} "
            f"for {asset.filename} — skipping"
        )
        return False
    if len(body) % 1024 == 0:
        # Vanishingly unlikely now that we Range-recovered, but defend.
        print(f"  ✗ Recovered bytes are themselves 1024-aligned, refusing")
        return False
    if apply:
        atomic_write(asset.local_path, body)
        print(f"  ✓ Restored from versions: {len(body)}B")
    else:
        print(f"  [dry-run] would restore {len(body)}B from {asset.clean_version_href}")
    return True


def recover_phase_b(asset: TruncatedAsset, apply: bool) -> bool:
    if not asset.pdf_source or not asset.pixel_width:
        return False
    # PDF page size in points: peek pdfinfo for the source PDF.
    try:
        info = subprocess.run(
            ["pdfinfo", str(asset.pdf_source)],
            capture_output=True, text=True, check=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print(f"  ✗ pdfinfo failed: {e}")
        return False
    page_w_pts = None
    for line in info.stdout.splitlines():
        if line.startswith("Page size:"):
            # "Page size:       960 x 540 pts"
            try:
                parts = line.split(":")[1].strip().split()
                page_w_pts = float(parts[0])
            except (IndexError, ValueError):
                pass
            break
    if not page_w_pts:
        print(f"  ✗ Could not parse Page size from pdfinfo")
        return False
    # Derive the DPI the app used: pixel_width = page_w_pts / 72 * dpi
    dpi = round(asset.pixel_width * 72.0 / page_w_pts)
    if dpi < 50 or dpi > 400:
        print(f"  ✗ Derived DPI {dpi} out of sane range — skipping")
        return False
    with tempfile.TemporaryDirectory() as td:
        out_prefix = Path(td) / "page"
        # pdftocairo: -png -r <dpi> -f N -l N
        try:
            subprocess.run(
                [
                    "pdftocairo", "-png",
                    "-r", str(dpi),
                    "-f", str(asset.pdf_page),
                    "-l", str(asset.pdf_page),
                    str(asset.pdf_source),
                    str(out_prefix),
                ],
                capture_output=True, check=True,
            )
        except subprocess.CalledProcessError as e:
            print(f"  ✗ pdftocairo failed: {e.stderr.decode(errors='replace')[:200]}")
            return False
        # pdftocairo names: page-<NN>.png with zero-padded page index.
        # Width of the index varies. Use glob.
        rendered = list(Path(td).glob("page-*.png"))
        if not rendered:
            print(f"  ✗ pdftocairo produced no file")
            return False
        out_bytes = rendered[0].read_bytes()
    if not out_bytes:
        print(f"  ✗ Rendered file is empty")
        return False
    if len(out_bytes) % 1024 == 0:
        # Vanishingly unlikely for a clean render, but defend against it.
        print(f"  ⚠ Render is incidentally 1024-aligned ({len(out_bytes)}B) — proceeding")
    # Sanity: re-decode width should match original
    rendered_w, rendered_h = (None, None)
    if len(out_bytes) > 24:
        rendered_w = int.from_bytes(out_bytes[16:20], "big")
        rendered_h = int.from_bytes(out_bytes[20:24], "big")
    if (rendered_w, rendered_h) != (asset.pixel_width, asset.pixel_height):
        print(
            f"  ⚠ Dim drift: render {rendered_w}x{rendered_h} "
            f"vs original {asset.pixel_width}x{asset.pixel_height} "
            f"(DPI={dpi}) — proceeding anyway, canvas uses normalized dims"
        )
    if apply:
        atomic_write(asset.local_path, out_bytes)
        print(f"  ✓ Rerendered {asset.pdf_name} p{asset.pdf_page} @ {dpi} DPI → {len(out_bytes)}B")
    else:
        print(
            f"  [dry-run] would write {len(out_bytes)}B "
            f"({asset.pdf_name} p{asset.pdf_page} @ {dpi} DPI)"
        )
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true",
                    help="Actually write recovered bytes (default: dry run).")
    ap.add_argument("--phase", choices=["A", "B", "AB"], default="AB",
                    help="A = versions API only, B = PDF rerender only, AB = both.")
    args = ap.parse_args()

    if not MIRROR_ROOT.exists():
        sys.exit(f"Mirror not found: {MIRROR_ROOT}")
    if not PREFS_PATH.exists() and "A" in args.phase:
        sys.exit(f"Credentials not found: {PREFS_PATH}")

    server = user = auth = None
    if "A" in args.phase:
        server, user, auth = load_credentials()

    print(f"Scanning {MIRROR_ROOT}/_delta for 1024-aligned PNG assets...")
    truncated = scan_truncated(MIRROR_ROOT)
    print(f"Found {len(truncated)} candidate(s)")
    print()

    # Phase A: detect Versions API recoverability
    if "A" in args.phase:
        print("─── Phase A: probing Versions API ───")
        for a in truncated:
            query_clean_version(server, user, auth, a)
            if a.clean_version_href:
                a.recovery_phase = "A"
        a_count = sum(1 for a in truncated if a.recovery_phase == "A")
        print(f"  {a_count} asset(s) have a clean historical version")
        print()

    # Phase B: locate PDF for re-render fallback
    if "B" in args.phase:
        print("─── Phase B: locating source PDFs ───")
        pdf_cache = {}
        for a in truncated:
            if a.recovery_phase == "A":
                continue
            if a.pdf_name not in pdf_cache:
                pdf_cache[a.pdf_name] = find_source_pdf(a.pdf_name)
            a.pdf_source = pdf_cache[a.pdf_name]
            if a.pdf_source:
                a.recovery_phase = "B"
        b_count = sum(1 for a in truncated if a.recovery_phase == "B")
        missing = sorted({a.pdf_name for a in truncated if a.recovery_phase is None})
        print(f"  {b_count} asset(s) re-renderable from PDF")
        if missing:
            print(f"  Missing source PDFs: {missing}")
        print()

    # Pre-resolve PDF source for ALL assets that have one. This way Phase A
    # failures can transparently fall through to Phase B re-render.
    if "B" not in args.phase:
        pass
    else:
        pdf_cache = {a.pdf_name: a.pdf_source for a in truncated if a.pdf_source}
        for a in truncated:
            if a.pdf_source is None and a.pdf_name not in pdf_cache:
                pdf_cache[a.pdf_name] = find_source_pdf(a.pdf_name)
            if a.pdf_source is None:
                a.pdf_source = pdf_cache.get(a.pdf_name)

    # Execute (or dry-run print)
    print(f"─── {'APPLYING' if args.apply else 'DRY RUN'} ───")
    succ_a = succ_b = fail = 0
    for a in truncated:
        print(f"• {a.filename} ({a.local_size}B)")
        if a.recovery_phase == "A":
            if recover_phase_a(server, user, auth, a, args.apply):
                succ_a += 1
                continue
            # Phase A failed — fall through to Phase B if PDF available.
            if "B" in args.phase and a.pdf_source:
                print(f"  ↻ falling back to PDF re-render")
                if recover_phase_b(a, args.apply):
                    succ_b += 1
                    continue
            fail += 1
        elif a.recovery_phase == "B":
            if recover_phase_b(a, args.apply):
                succ_b += 1
            else:
                fail += 1
        else:
            print(f"  ✗ unrecoverable (no clean version, no source PDF)")
            fail += 1
    print()
    print(f"═══ Summary ═══")
    print(f"  Restored from versions: {succ_a}")
    print(f"  Re-rendered from PDF:   {succ_b}")
    print(f"  Failed/unrecoverable:   {fail}")
    if not args.apply:
        print()
        print("Dry run only. Re-run with --apply to perform the writes.")


if __name__ == "__main__":
    main()
