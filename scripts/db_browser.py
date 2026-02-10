#!/usr/bin/env python3
import json
import os
import re
import sqlite3
import sys
import unicodedata
from typing import Dict, List


DEFAULT_DB_CANDIDATES = [
    os.path.join("artefacts", "icon.db"),
    os.path.join("nut", "build_artefacts", "icon.db"),
]

DEFAULT_TITLES_CANDIDATES = [
    os.path.join("artefacts", "titles.US.en.json"),
    os.path.join("nut", "build_artefacts", "titles.US.en.json"),
    os.path.join("nut", "titledb", "US.en.json"),
]


def pick_existing_path(candidates: List[str]) -> str:
    for p in candidates:
        if os.path.exists(p):
            return p
    return ""


def normalize_title_id(value: str) -> str:
    return str(value or "").strip().upper()


def normalize_search_text(value: str) -> str:
    text = str(value or "").strip().casefold()
    text = unicodedata.normalize("NFKD", text)
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = "".join(ch if ch.isalnum() or ch.isspace() else " " for ch in text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def load_titles_index(path: str) -> Dict[str, str]:
    if not path or not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as f:
        payload = json.load(f)
    if not isinstance(payload, dict):
        return {}

    out: Dict[str, str] = {}
    for map_key, entry in payload.items():
        if not isinstance(entry, dict):
            continue
        title_id = normalize_title_id(entry.get("id") or map_key)
        if not title_id:
            continue
        name = (
            str(entry.get("name") or entry.get("title") or entry.get("displayName") or "")
            .strip()
        )
        out[title_id] = name
    return out


def connect_db(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    return conn


def format_bytes(num_bytes: int) -> str:
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    size = float(max(0, int(num_bytes)))
    idx = 0
    while size >= 1024.0 and idx < len(units) - 1:
        size /= 1024.0
        idx += 1
    if idx == 0:
        return f"{int(size)} {units[idx]}"
    return f"{size:.2f} {units[idx]}"


def get_db_info(conn: sqlite3.Connection, db_path: str) -> Dict[str, int]:
    cur = conn.cursor()
    cur.execute("SELECT COUNT(*) AS c FROM images")
    rows = int(cur.fetchone()["c"])
    cur.execute("SELECT COALESCE(SUM(size_bytes), 0) AS s FROM images")
    blob_sum = int(cur.fetchone()["s"])
    file_size = os.path.getsize(db_path) if os.path.exists(db_path) else 0
    return {"rows": rows, "blob_sum": blob_sum, "file_size": file_size}


def search_by_name(
    conn: sqlite3.Connection, titles_index: Dict[str, str], query: str, limit: int
) -> List[sqlite3.Row]:
    q = normalize_search_text(query)
    if not q:
        return []
    matched_ids = [
        tid for tid, name in titles_index.items() if q in normalize_search_text(name)
    ]
    if not matched_ids:
        return []

    out: List[sqlite3.Row] = []
    cur = conn.cursor()
    chunk_size = 400
    for i in range(0, len(matched_ids), chunk_size):
        chunk = matched_ids[i : i + chunk_size]
        placeholders = ",".join(["?"] * len(chunk))
        sql = (
            "SELECT title_id, url, format, width, height, size_bytes, fetched_at "
            f"FROM images WHERE title_id IN ({placeholders}) ORDER BY title_id"
        )
        cur.execute(sql, chunk)
        out.extend(cur.fetchall())
        if len(out) >= limit:
            return out[:limit]
    return out[:limit]


def extract_image(conn: sqlite3.Connection, title_id: str, out_dir: str) -> str:
    cur = conn.cursor()
    cur.execute("SELECT format, image FROM images WHERE title_id = ?", (title_id,))
    row = cur.fetchone()
    if row is None:
        raise RuntimeError(f"title_id not found in DB: {title_id}")
    fmt = str(row["format"] or "bin").strip().lower() or "bin"
    blob = row["image"]
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, f"{title_id}.{fmt}")
    with open(out_path, "wb") as f:
        f.write(blob)
    return out_path


def print_menu() -> None:
    print("")
    print("1) Show DB info")
    print("2) Search by game name")
    print("3) Change DB path")
    print("4) Exit")


def main() -> int:
    db_path = pick_existing_path(DEFAULT_DB_CANDIDATES)
    if not db_path:
        db_path = input("DB path not found automatically. Enter path to db: ").strip()
    if not db_path or not os.path.exists(db_path):
        print(f"DB file not found: {db_path}")
        return 1

    titles_path = pick_existing_path(DEFAULT_TITLES_CANDIDATES)
    titles_index = load_titles_index(titles_path)

    while True:
        print("")
        print(f"Current DB: {db_path}")
        print(f"Titles index: {titles_path or 'not found'} ({len(titles_index)} titles)")
        print_menu()
        choice = input("Select option: ").strip()

        if choice == "1":
            try:
                conn = connect_db(db_path)
                info = get_db_info(conn, db_path)
                conn.close()
                print("")
                print("DB Info")
                print(f"- Rows in images table: {info['rows']}")
                print(
                    f"- Total image bytes (size_bytes sum): "
                    f"{format_bytes(info['blob_sum'])} ({info['blob_sum']} B)"
                )
                print(
                    f"- DB file size: "
                    f"{format_bytes(info['file_size'])} ({info['file_size']} B)"
                )
            except Exception as e:
                print(f"Failed to read DB info: {e}")

        elif choice == "2":
            if not titles_index:
                print("Titles index not loaded. Cannot search by name.")
                continue
            query = input("Enter name search text: ").strip()
            limit_raw = input("Limit results [default 25]: ").strip() or "25"
            try:
                limit = max(1, int(limit_raw))
            except ValueError:
                limit = 25
            try:
                conn = connect_db(db_path)
                rows = search_by_name(conn, titles_index, query, limit)
                if not rows:
                    conn.close()
                    print("No matching rows found in DB.")
                    continue
                print("")
                print(f"Found {len(rows)} result(s):")
                for idx, r in enumerate(rows, start=1):
                    title_id = normalize_title_id(r["title_id"])
                    name = titles_index.get(title_id, "(unknown)")
                    print(
                        f"{idx}) {name} | {title_id} | {r['format']} {r['width']}x{r['height']} | "
                        f"bytes={r['size_bytes']} | fetched={r['fetched_at']}"
                    )

                print("")
                pick = input("Extract image? Enter result number (or press Enter to skip): ").strip()
                if not pick:
                    conn.close()
                    continue
                try:
                    pick_idx = int(pick)
                except ValueError:
                    conn.close()
                    print("Invalid number")
                    continue
                if pick_idx < 1 or pick_idx > len(rows):
                    conn.close()
                    print("Result number out of range")
                    continue
                out_dir = input("Output directory [default extracted_images]: ").strip() or "extracted_images"
                selected = rows[pick_idx - 1]
                selected_id = normalize_title_id(selected["title_id"])
                out_path = extract_image(conn, selected_id, out_dir)
                conn.close()
                print(f"Extracted: {out_path}")
            except Exception as e:
                print(f"Search failed: {e}")

        elif choice == "3":
            new_path = input("Enter new DB path: ").strip()
            if not os.path.exists(new_path):
                print(f"File not found: {new_path}")
                continue
            db_path = new_path

        elif choice == "4":
            print("Bye")
            return 0

        else:
            print("Invalid option")


if __name__ == "__main__":
    sys.exit(main())
