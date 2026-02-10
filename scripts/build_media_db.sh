#!/usr/bin/env bash
set -euo pipefail

cd /workspace
mkdir -p artefacts

MODE="${MEDIA_DB_MODE:-both}"
case "$MODE" in
  icons|banners|both) ;;
  *)
    echo "Invalid MEDIA_DB_MODE: '$MODE' (expected: icons, banners, both)"
    exit 1
    ;;
esac
echo "Running media DB build mode: $MODE"
RESET="${MEDIA_DB_RESET:-0}"

if [ ! -d nut ]; then
  cp -a /opt/nut nut
fi

cd nut

if [ ! -d titledb/.git ]; then
  rm -rf titledb
  git clone --depth=1 --filter=blob:none --sparse https://github.com/blawar/titledb titledb
  git -C titledb sparse-checkout set US.en.json
elif [ ! -f titledb/US.en.json ]; then
  git -C titledb sparse-checkout set US.en.json
  git -C titledb pull --ff-only
fi

mkdir -p build_artefacts

if [ "$RESET" = "1" ]; then
  if [ "$MODE" = "both" ] || [ "$MODE" = "icons" ]; then
    rm -f build_artefacts/icon.db
  fi
  if [ "$MODE" = "both" ] || [ "$MODE" = "banners" ]; then
    rm -f build_artefacts/banners.db
  fi
  echo "Reset enabled: removed selected DB files before processing"
fi

python - <<'PY'
import json
import os
import sys

os.chdir(os.getcwd())
sys.path.append(os.getcwd())
import nut

nut.importRegion("US", "en")
os.rename("titledb/titles.json", "build_artefacts/titles.US.en.json")
print("Generated build_artefacts/titles.US.en.json")
PY

python - <<'PY'
import hashlib
import io
import json
import os
import sqlite3
import time
from datetime import datetime, timezone

import requests
from PIL import Image, ImageOps
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

TITLES_PATH = "build_artefacts/titles.US.en.json"
ICON_DB_PATH = "build_artefacts/icon.db"
BANNER_DB_PATH = "build_artefacts/banners.db"
TARGET_SIZE = (128, 128)
MODE = os.environ.get("MEDIA_DB_MODE", "both").strip().lower()
BUILD_ICONS = MODE in ("both", "icons")
BUILD_BANNERS = MODE in ("both", "banners")
ARTEFACTS_DIR = "/workspace/artefacts"

def now_iso():
    return datetime.now(timezone.utc).isoformat()

def write_json(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, sort_keys=True)

def build_session():
    retry = Retry(
        total=4,
        read=4,
        connect=4,
        backoff_factor=0.5,
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=frozenset(["GET"]),
    )
    adapter = HTTPAdapter(max_retries=retry)
    s = requests.Session()
    s.mount("http://", adapter)
    s.mount("https://", adapter)
    s.headers.update({"User-Agent": "ownfoil-media-db-builder/1.0"})
    return s

def ensure_db(path):
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode=OFF")
    conn.execute("PRAGMA synchronous=OFF")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS images (
            title_id TEXT PRIMARY KEY,
            url TEXT NOT NULL,
            format TEXT NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            size_bytes INTEGER NOT NULL,
            source_sha256 TEXT NOT NULL,
            fetched_at TEXT NOT NULL,
            image BLOB NOT NULL
        )
        """
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_images_url ON images(url)")
    return conn

def load_titles(path):
    with open(path, "r", encoding="utf-8") as f:
        payload = json.load(f)
    if isinstance(payload, dict):
        return payload
    return {}

def collect_links(entries, key_name):
    out = {}
    for map_key, entry in entries.items():
        if not isinstance(entry, dict):
            continue
        title_id = str(entry.get("id") or map_key or "").strip().upper()
        if not title_id:
            continue
        url = str(entry.get(key_name) or "").strip()
        if not url:
            continue
        out[title_id] = url
    return out

def fetch_and_resize(session, url):
    resp = session.get(url, timeout=20)
    resp.raise_for_status()
    source_bytes = resp.content
    source_sha = hashlib.sha256(source_bytes).hexdigest()

    with Image.open(io.BytesIO(source_bytes)) as im:
        im = ImageOps.exif_transpose(im)
        if im.mode not in ("RGB", "RGBA"):
            im = im.convert("RGB")
        elif im.mode == "RGBA":
            bg = Image.new("RGB", im.size, (255, 255, 255))
            bg.paste(im, mask=im.split()[-1])
            im = bg
        fitted = ImageOps.fit(im, TARGET_SIZE, method=Image.Resampling.LANCZOS)

        out = io.BytesIO()
        fitted.save(out, format="WEBP", quality=80, method=6)
        out_bytes = out.getvalue()
    return out_bytes, source_sha

def existing_url_map(conn):
    cur = conn.cursor()
    cur.execute("SELECT title_id, url FROM images")
    return {row[0]: row[1] for row in cur.fetchall()}

def db_snapshot(conn, db_path):
    cur = conn.cursor()
    cur.execute("SELECT COUNT(*) FROM images")
    rows = int(cur.fetchone()[0] or 0)
    cur.execute("SELECT COALESCE(SUM(size_bytes), 0) FROM images")
    total_size_bytes = int(cur.fetchone()[0] or 0)
    return {
        "rows": rows,
        "total_size_bytes": total_size_bytes,
        "db_file_size_bytes": int(os.path.getsize(db_path)) if os.path.exists(db_path) else 0,
    }

def populate_db(conn, items, label):
    session = build_session()
    ok = 0
    failed = 0
    bytes_total = 0
    new_rows = 0
    updated_rows = 0
    skipped_unchanged = 0
    progress_every = 100
    commit_every = 100
    total = len(items)
    start_ts = time.time()
    progress_path = os.path.join(ARTEFACTS_DIR, f"{label}.progress.json")
    summary_path = os.path.join(ARTEFACTS_DIR, f"{label}.summary.json")
    cur = conn.cursor()

    existing = existing_url_map(conn)
    planned = []
    for title_id, url in items.items():
        prev_url = existing.get(title_id)
        if prev_url == url:
            skipped_unchanged += 1
            continue
        planned.append((title_id, url, prev_url))

    start_state = {
        "label": label,
        "mode": MODE,
        "started_at": now_iso(),
        "total_input_links": total,
        "existing_rows_in_db": len(existing),
        "skipped_unchanged": skipped_unchanged,
        "to_process": len(planned),
        "processed": 0,
        "ok": 0,
        "failed": 0,
        "new_rows": 0,
        "updated_rows": 0,
        "bytes_written_this_run": 0,
        "rate_items_per_sec": 0.0,
        "eta_seconds": 0,
        "completed": False,
    }
    write_json(progress_path, start_state)
    print(
        f"[{label}] state total={total} db_existing={len(existing)} "
        f"skipped_unchanged={skipped_unchanged} to_process={len(planned)}"
    )

    if not planned:
        end_snapshot = db_snapshot(conn, ICON_DB_PATH if label == "icon" else BANNER_DB_PATH)
        done = dict(start_state)
        done["completed"] = True
        done["finished_at"] = now_iso()
        done["db_rows"] = end_snapshot["rows"]
        done["db_total_size_bytes"] = end_snapshot["total_size_bytes"]
        done["db_file_size_bytes"] = end_snapshot["db_file_size_bytes"]
        write_json(progress_path, done)
        write_json(summary_path, done)
        print(f"[{label}] nothing to do (already up to date)")
        return 0, 0, 0

    for idx, (title_id, url, prev_url) in enumerate(planned, start=1):
        try:
            webp_bytes, source_sha = fetch_and_resize(session, url)
            cur.execute(
                """
                INSERT OR REPLACE INTO images
                (title_id, url, format, width, height, size_bytes, source_sha256, fetched_at, image)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    title_id,
                    url,
                    "webp",
                    TARGET_SIZE[0],
                    TARGET_SIZE[1],
                    len(webp_bytes),
                    source_sha,
                    now_iso(),
                    sqlite3.Binary(webp_bytes),
                ),
            )
            ok += 1
            bytes_total += len(webp_bytes)
            if prev_url is None:
                new_rows += 1
            else:
                updated_rows += 1
        except Exception as e:
            failed += 1
            print(f"[{label}] failed {idx}/{len(planned)} {title_id}: {e}")
        if idx % commit_every == 0:
            conn.commit()
        if idx % progress_every == 0:
            elapsed = max(time.time() - start_ts, 0.001)
            rate = idx / elapsed
            remaining = len(planned) - idx
            eta_seconds = int(remaining / rate) if rate > 0 else 0
            payload = {
                "label": label,
                "mode": MODE,
                "started_at": start_state["started_at"],
                "updated_at": now_iso(),
                "total_input_links": total,
                "existing_rows_in_db": len(existing),
                "skipped_unchanged": skipped_unchanged,
                "to_process": len(planned),
                "processed": idx,
                "ok": ok,
                "failed": failed,
                "new_rows": new_rows,
                "updated_rows": updated_rows,
                "bytes_written_this_run": bytes_total,
                "rate_items_per_sec": round(rate, 2),
                "eta_seconds": eta_seconds,
                "completed": False,
            }
            write_json(progress_path, payload)
            print(
                f"[{label}] progress {idx}/{len(planned)} ok={ok} failed={failed} "
                f"new={new_rows} updated={updated_rows} skip={skipped_unchanged} "
                f"rate={rate:.2f}/s eta={eta_seconds}s"
            )
    conn.commit()
    end_snapshot = db_snapshot(conn, ICON_DB_PATH if label == "icon" else BANNER_DB_PATH)
    elapsed = max(time.time() - start_ts, 0.001)
    done = {
        "label": label,
        "mode": MODE,
        "started_at": start_state["started_at"],
        "finished_at": now_iso(),
        "total_input_links": total,
        "existing_rows_in_db": len(existing),
        "skipped_unchanged": skipped_unchanged,
        "to_process": len(planned),
        "processed": len(planned),
        "ok": ok,
        "failed": failed,
        "new_rows": new_rows,
        "updated_rows": updated_rows,
        "bytes_written_this_run": bytes_total,
        "rate_items_per_sec": round(len(planned) / elapsed, 2),
        "eta_seconds": 0,
        "db_rows": end_snapshot["rows"],
        "db_total_size_bytes": end_snapshot["total_size_bytes"],
        "db_file_size_bytes": end_snapshot["db_file_size_bytes"],
        "completed": True,
    }
    write_json(progress_path, done)
    write_json(summary_path, done)
    print(
        f"[{label}] done ok={ok} failed={failed} new={new_rows} updated={updated_rows} "
        f"skip={skipped_unchanged} db_rows={end_snapshot['rows']} "
        f"db_size={end_snapshot['db_file_size_bytes']} bytes"
    )
    return ok, failed, bytes_total

entries = load_titles(TITLES_PATH)
icon_items = collect_links(entries, "iconUrl")
banner_items = collect_links(entries, "bannerUrl")

print(f"Found icon links: {len(icon_items)}")
print(f"Found banner links: {len(banner_items)}")

if BUILD_ICONS:
    icon_conn = ensure_db(ICON_DB_PATH)
    try:
        populate_db(icon_conn, icon_items, "icon")
    finally:
        icon_conn.close()
    print(f"Wrote {ICON_DB_PATH}")
else:
    print("Skipping icon.db build")

if BUILD_BANNERS:
    banner_conn = ensure_db(BANNER_DB_PATH)
    try:
        populate_db(banner_conn, banner_items, "banner")
    finally:
        banner_conn.close()
    print(f"Wrote {BANNER_DB_PATH}")
else:
    print("Skipping banners.db build")
PY

cp build_artefacts/titles.US.en.json /workspace/artefacts/titles.US.en.json
if [ -f build_artefacts/icon.db ]; then
  cp build_artefacts/icon.db /workspace/artefacts/icon.db
fi
if [ -f build_artefacts/banners.db ]; then
  cp build_artefacts/banners.db /workspace/artefacts/banners.db
fi

echo "Done. Output files are in /workspace/artefacts"
