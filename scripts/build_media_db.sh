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
RESET="${MEDIA_DB_RESET:-0}"
EXPORT_PACKS="${MEDIA_DB_EXPORT_PACKS:-1}"
FORCE_TITLES_REFRESH="${MEDIA_DB_FORCE_TITLES_REFRESH:-0}"
CHECK_UPDATES_ONLY="${MEDIA_DB_CHECK_UPDATES_ONLY:-0}"
MANIFEST_BASE_URL="${MEDIA_DB_MANIFEST_BASE_URL:-}"
MANIFEST_NAME="${MEDIA_DB_MANIFEST_NAME:-offline_db_manifest.json}"
DB_VERSION="${MEDIA_DB_VERSION:-}"

echo "Running media DB build mode: $MODE"
echo "Reset: $RESET, Export packs: $EXPORT_PACKS, Force titles refresh: $FORCE_TITLES_REFRESH, Check-only: $CHECK_UPDATES_ONLY"
echo "Manifest config: base_url='${MANIFEST_BASE_URL:-<relative file paths>}' name='$MANIFEST_NAME' db_version='${DB_VERSION:-<auto UTC timestamp>}'"

if [ ! -d nut ]; then
  cp -a /opt/nut nut
fi

cd nut
mkdir -p build_artefacts

if [ ! -d titledb/.git ]; then
  rm -rf titledb
  git clone --depth=1 https://github.com/blawar/titledb titledb
fi

git -C titledb pull --ff-only

if [ "$RESET" = "1" ]; then
  if [ "$MODE" = "both" ] || [ "$MODE" = "icons" ]; then
    rm -f build_artefacts/icon.db
  fi
  if [ "$MODE" = "both" ] || [ "$MODE" = "banners" ]; then
    rm -f build_artefacts/banners.db
  fi
  echo "Reset enabled: removed selected DB files before processing"
fi

TITLEDB_JSON_PATH="titledb/US.en.json"
GENERATED_TITLES_PATH="build_artefacts/titles.US.en.json"
PREVIOUS_TITLES_PATH="build_artefacts/titles.US.en.prev.json"
TITLEDB_HASH_PATH="build_artefacts/titles.US.en.source.sha256"

if [ ! -f "$TITLEDB_JSON_PATH" ]; then
  echo "Missing titledb source file: $TITLEDB_JSON_PATH"
  exit 1
fi

CURRENT_SOURCE_HASH="$(sha256sum "$TITLEDB_JSON_PATH" | awk '{print $1}')"
PREVIOUS_SOURCE_HASH=""
if [ -f "$TITLEDB_HASH_PATH" ]; then
  PREVIOUS_SOURCE_HASH="$(cat "$TITLEDB_HASH_PATH")"
fi

REBUILD_TITLES="0"
REBUILD_REASON="up_to_date"
if [ ! -f "$GENERATED_TITLES_PATH" ]; then
  REBUILD_TITLES="1"
  REBUILD_REASON="missing_generated_file"
elif [ "$FORCE_TITLES_REFRESH" = "1" ]; then
  REBUILD_TITLES="1"
  REBUILD_REASON="forced_refresh"
elif [ "$CURRENT_SOURCE_HASH" != "$PREVIOUS_SOURCE_HASH" ]; then
  REBUILD_TITLES="1"
  REBUILD_REASON="upstream_changed"
fi

echo "Titles source hash: $CURRENT_SOURCE_HASH"
if [ -n "$PREVIOUS_SOURCE_HASH" ]; then
  echo "Previous source hash: $PREVIOUS_SOURCE_HASH"
fi
echo "Titles rebuild: $REBUILD_TITLES ($REBUILD_REASON)"

if [ "$REBUILD_TITLES" = "1" ]; then
  if [ -f "$GENERATED_TITLES_PATH" ]; then
    cp "$GENERATED_TITLES_PATH" "$PREVIOUS_TITLES_PATH"
  else
    rm -f "$PREVIOUS_TITLES_PATH"
  fi

  python - <<'PY'
import os
import sys

sys.path.append(os.getcwd())
import nut

nut.importRegion("US", "en")
os.rename("titledb/titles.json", "build_artefacts/titles.US.en.json")
print("Generated build_artefacts/titles.US.en.json")
PY
else
  cp "$GENERATED_TITLES_PATH" "$PREVIOUS_TITLES_PATH"
fi

export TITLES_PROGRESS_PATH="/workspace/artefacts/titles.progress.json"
export TITLES_SUMMARY_PATH="/workspace/artefacts/titles.summary.json"
export GENERATED_TITLES_PATH
export PREVIOUS_TITLES_PATH
export CURRENT_SOURCE_HASH
export PREVIOUS_SOURCE_HASH
export REBUILD_TITLES
export REBUILD_REASON
export CHECK_UPDATES_ONLY

python - <<'PY'
import json
import os
from datetime import datetime, timezone

METADATA_FIELDS = (
    "name",
    "publisher",
    "intro",
    "description",
    "size",
    "version",
    "releaseDate",
    "isDemo",
)


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def write_json(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, sort_keys=True)


def normalize(payload):
    out = {}
    if not isinstance(payload, dict):
        return out
    for map_key, entry in payload.items():
        if not isinstance(entry, dict):
            continue
        title_id = str(entry.get("id") or map_key or "").strip().upper()
        if not title_id:
            continue
        out[title_id] = entry
    return out


def load_titles(path):
    if not path or not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as f:
        return normalize(json.load(f))


current_titles = load_titles(os.environ["GENERATED_TITLES_PATH"])
previous_titles = load_titles(os.environ["PREVIOUS_TITLES_PATH"])

all_ids = set(current_titles) | set(previous_titles)
added_titles = 0
removed_titles = 0
metadata_changed_titles = 0
icon_url_changed_titles = 0
banner_url_changed_titles = 0
unchanged_titles = 0

for title_id in all_ids:
    old = previous_titles.get(title_id)
    new = current_titles.get(title_id)
    if old is None:
        added_titles += 1
        continue
    if new is None:
        removed_titles += 1
        continue

    metadata_changed = any(old.get(field) != new.get(field) for field in METADATA_FIELDS)
    icon_changed = (old.get("iconUrl") or "") != (new.get("iconUrl") or "")
    banner_changed = (old.get("bannerUrl") or "") != (new.get("bannerUrl") or "")

    if metadata_changed:
        metadata_changed_titles += 1
    if icon_changed:
        icon_url_changed_titles += 1
    if banner_changed:
        banner_url_changed_titles += 1
    if not (metadata_changed or icon_changed or banner_changed):
        unchanged_titles += 1

summary = {
    "started_at": now_iso(),
    "finished_at": now_iso(),
    "source_sha256": os.environ.get("CURRENT_SOURCE_HASH", ""),
    "previous_source_sha256": os.environ.get("PREVIOUS_SOURCE_HASH", ""),
    "rebuilt_titles_json": os.environ.get("REBUILD_TITLES") == "1",
    "rebuild_reason": os.environ.get("REBUILD_REASON", ""),
    "check_updates_only": os.environ.get("CHECK_UPDATES_ONLY") == "1",
    "total_titles_current": len(current_titles),
    "total_titles_previous": len(previous_titles),
    "added_titles": added_titles,
    "removed_titles": removed_titles,
    "metadata_changed_titles": metadata_changed_titles,
    "icon_url_changed_titles": icon_url_changed_titles,
    "banner_url_changed_titles": banner_url_changed_titles,
    "unchanged_titles": unchanged_titles,
    "completed": True,
}

write_json(os.environ["TITLES_PROGRESS_PATH"], summary)
write_json(os.environ["TITLES_SUMMARY_PATH"], summary)

print(
    "[titles] summary "
    f"current={summary['total_titles_current']} previous={summary['total_titles_previous']} "
    f"added={added_titles} removed={removed_titles} "
    f"metadata_changed={metadata_changed_titles} icon_url_changed={icon_url_changed_titles} "
    f"banner_url_changed={banner_url_changed_titles} unchanged={unchanged_titles}"
)
PY

echo "$CURRENT_SOURCE_HASH" > "$TITLEDB_HASH_PATH"
rm -f "$PREVIOUS_TITLES_PATH"

if [ "$CHECK_UPDATES_ONLY" = "1" ]; then
  cp "$GENERATED_TITLES_PATH" /workspace/artefacts/titles.US.en.json
  echo "Update check complete (MEDIA_DB_CHECK_UPDATES_ONLY=1)."
  echo "Wrote /workspace/artefacts/titles.summary.json and /workspace/artefacts/titles.progress.json"
  exit 0
fi

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
    removed_rows = 0
    skipped_unchanged = 0
    progress_every = 100
    commit_every = 100
    total = len(items)
    start_ts = time.time()
    progress_path = os.path.join(ARTEFACTS_DIR, f"{label}.progress.json")
    summary_path = os.path.join(ARTEFACTS_DIR, f"{label}.summary.json")
    cur = conn.cursor()

    existing = existing_url_map(conn)
    removed_ids = sorted(set(existing) - set(items))
    if removed_ids:
        for offset in range(0, len(removed_ids), 500):
            chunk = removed_ids[offset : offset + 500]
            cur.executemany("DELETE FROM images WHERE title_id = ?", [(title_id,) for title_id in chunk])
        conn.commit()
        removed_rows = len(removed_ids)
        for title_id in removed_ids:
            existing.pop(title_id, None)

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
        "removed_rows": removed_rows,
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
        f"[{label}] state total={total} db_existing={len(existing)} removed={removed_rows} "
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
        print(f"[{label}] nothing to download (already up to date)")
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
                "removed_rows": removed_rows,
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
                f"new={new_rows} updated={updated_rows} removed={removed_rows} "
                f"skip={skipped_unchanged} rate={rate:.2f}/s eta={eta_seconds}s"
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
        "removed_rows": removed_rows,
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
        f"removed={removed_rows} skip={skipped_unchanged} db_rows={end_snapshot['rows']} "
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

cp "$GENERATED_TITLES_PATH" /workspace/artefacts/titles.US.en.json
if [ -f build_artefacts/icon.db ]; then
  cp build_artefacts/icon.db /workspace/artefacts/icon.db
fi
if [ -f build_artefacts/banners.db ]; then
  cp build_artefacts/banners.db /workspace/artefacts/banners.db
fi

if [ "$EXPORT_PACKS" = "1" ]; then
  EXPORT_SCRIPT="/usr/local/bin/export_offline_db.py"
  if [ ! -f "$EXPORT_SCRIPT" ]; then
    EXPORT_SCRIPT="/workspace/scripts/export_offline_db.py"
  fi

  if [ -f "$EXPORT_SCRIPT" ]; then
    export_args=(--source-dir /workspace/artefacts --output-dir /workspace/artefacts)
    if [ -n "$MANIFEST_BASE_URL" ]; then
      export_args+=(--manifest-base-url "$MANIFEST_BASE_URL")
    fi
    if [ -n "$DB_VERSION" ]; then
      export_args+=(--db-version "$DB_VERSION")
    fi
    if [ -n "$MANIFEST_NAME" ]; then
      export_args+=(--manifest-name "$MANIFEST_NAME")
    fi
    if [ ! -f /workspace/artefacts/icon.db ]; then
      export_args+=(--skip-icons)
    fi
    if [ ! -f /workspace/artefacts/titles.US.en.json ]; then
      export_args+=(--skip-metadata)
    fi
    python "$EXPORT_SCRIPT" "${export_args[@]}"
  else
    echo "Skipping pack export: export_offline_db.py not found"
  fi
else
  echo "Skipping pack export (MEDIA_DB_EXPORT_PACKS=$EXPORT_PACKS)"
fi

echo "Done. Output files are in /workspace/artefacts"
