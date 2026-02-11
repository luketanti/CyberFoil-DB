# CyberFoil-DB

CyberFoil-DB builds offline title metadata and media artefacts for CyberFoil, then exports runtime pack files plus a manifest.

Final target outputs:
- `artefacts/titles.pack`
- `artefacts/icons.pack`
- `artefacts/offline_db_manifest.json`

There is currently no `banners.pack` export in this pipeline.

## Pipeline Behavior

The container entrypoint (`scripts/build_media_db.sh`) performs this end-to-end flow:

1. Ensure `/workspace/nut` exists (copied from `/opt/nut` on first run).
2. Ensure `nut/titledb` exists and pull latest upstream changes.
3. Optionally reset DB files when `MEDIA_DB_RESET=1`.
4. Compute SHA-256 for `nut/titledb/US.en.json`.
5. Regenerate `titles.US.en.json` when required.
6. Write title change summaries (`titles.progress.json`, `titles.summary.json`).
7. If not check-only mode, incrementally update media DBs (`icon.db`, `banners.db`) based on URL changes.
8. Copy generated artefacts into `artefacts/`.
9. Export packs and manifest with `scripts/export_offline_db.py` unless disabled.

## Requirements

- Docker Desktop (or compatible Docker Engine) with Compose v2.
- Network access from container to:
  - GitHub (`blawar/nut`, `blawar/titledb`)
  - Nintendo image CDN URLs from title metadata.

## Quick Start

From repo root:

```bash
docker compose up --build
```

## Runtime Variables

| Variable | Default | Allowed values | Effect |
|---|---|---|---|
| `MEDIA_DB_MODE` | `both` | `icons`, `banners`, `both` | Select media DBs to process incrementally. |
| `MEDIA_DB_RESET` | `0` | `0`, `1` | Remove selected media DB files before processing. |
| `MEDIA_DB_EXPORT_PACKS` | `1` | `0`, `1` | Export `titles.pack`/`icons.pack` and write manifest when both packs are available. |
| `MEDIA_DB_FORCE_TITLES_REFRESH` | `0` | `0`, `1` | Force `titles.US.en.json` regeneration even if source hash is unchanged. |
| `MEDIA_DB_CHECK_UPDATES_ONLY` | `0` | `0`, `1` | Run title update check only, then exit before media download and pack export. |
| `MEDIA_DB_MANIFEST_BASE_URL` | empty | URL or empty | Base URL used for manifest file URLs. Empty uses relative file names. |
| `MEDIA_DB_MANIFEST_NAME` | `offline_db_manifest.json` | filename | Manifest output file name. |
| `MEDIA_DB_VERSION` | empty | string or empty | Manifest `db_version`. Empty uses current UTC timestamp (`yyyyMMddHHmmss`). |
| `PYTHONUNBUFFERED` | `1` | any | Python output buffering behavior. |

## Usage

### Bash

```bash
# Full pipeline
docker compose up --build

# Incremental icons only
MEDIA_DB_MODE=icons docker compose up

# Incremental banners only
MEDIA_DB_MODE=banners docker compose up

# Reset selected DBs first
MEDIA_DB_RESET=1 docker compose up

# Force titles regeneration
MEDIA_DB_FORCE_TITLES_REFRESH=1 docker compose up

# Check title updates only (no media download, no pack export)
MEDIA_DB_CHECK_UPDATES_ONLY=1 docker compose up

# Disable pack export
MEDIA_DB_EXPORT_PACKS=0 docker compose up

# Export packs + manifest with release download URLs and explicit version
MEDIA_DB_MANIFEST_BASE_URL=https://github.com/<owner>/<repo>/releases/latest/download MEDIA_DB_VERSION=20260211213000 docker compose up
```

### PowerShell

```powershell
# Full pipeline
docker compose up --build

# Incremental icons only
$env:MEDIA_DB_MODE="icons"; docker compose up

# Incremental banners only
$env:MEDIA_DB_MODE="banners"; docker compose up

# Reset selected DBs first
$env:MEDIA_DB_RESET="1"; docker compose up

# Force titles regeneration
$env:MEDIA_DB_FORCE_TITLES_REFRESH="1"; docker compose up

# Check title updates only
$env:MEDIA_DB_CHECK_UPDATES_ONLY="1"; docker compose up

# Disable pack export
$env:MEDIA_DB_EXPORT_PACKS="0"; docker compose up

# Export packs + manifest with release download URLs and explicit version
$env:MEDIA_DB_MANIFEST_BASE_URL="https://github.com/<owner>/<repo>/releases/latest/download"; $env:MEDIA_DB_VERSION="20260211213000"; docker compose up
```

## Generated Files

Primary outputs in `artefacts/`:
- `titles.pack`
- `icons.pack`
- `offline_db_manifest.json` (generated when both packs are exported)

Additional build/debug outputs in `artefacts/`:
- `titles.US.en.json`
- `icon.db`
- `banners.db` (when built)
- `titles.progress.json`
- `titles.summary.json`
- `icon.progress.json`
- `icon.summary.json`
- `banner.progress.json`
- `banner.summary.json`

Persistent internal cache under `nut/build_artefacts/`:
- `titles.US.en.source.sha256`
- `titles.US.en.json`
- `icon.db`
- `banners.db`

## Incremental Update Logic

### Title update detection

Source checked: `nut/titledb/US.en.json`.

`titles.US.en.json` is regenerated when:
- `nut/build_artefacts/titles.US.en.json` is missing.
- `MEDIA_DB_FORCE_TITLES_REFRESH=1`.
- SHA-256 differs from `nut/build_artefacts/titles.US.en.source.sha256`.

Title summary fields include:
- `added_titles`
- `removed_titles`
- `metadata_changed_titles`
- `icon_url_changed_titles`
- `banner_url_changed_titles`
- `unchanged_titles`

`metadata_changed_titles` compares these fields: `name`, `publisher`, `intro`, `description`, `size`, `version`, `releaseDate`, `isDemo`.

### Media DB incremental behavior

For selected media URLs (`iconUrl`, `bannerUrl`):
- Existing DB rows are read (`title_id -> url`).
- Removed titles are deleted from DB (`removed_rows`).
- Unchanged URLs are skipped (`skipped_unchanged`).
- Only new/changed URLs are downloaded and re-encoded.

Image processing settings:
- Resize: `128x128`
- Format: `WEBP`
- WEBP options: `quality=80`, `method=6`
- HTTP retries for `GET`: `429`, `500`, `502`, `503`, `504`

## Pack Export Details

Export script: `scripts/export_offline_db.py`.

Inputs:
- `icon.db` (`images` table)
- `titles.US.en.json`

Outputs:
- `titles.pack` (magic `CFTITLE1`)
- `icons.pack` (magic `CFICONP1`)
- `offline_db_manifest.json` (schema `1`, includes `db_version`, `generated_at_utc`, and file URL/size/SHA-256 metadata)

Automatic export command used by builder:

```bash
python /usr/local/bin/export_offline_db.py \
  --source-dir /workspace/artefacts \
  --output-dir /workspace/artefacts \
  [--manifest-base-url "$MEDIA_DB_MANIFEST_BASE_URL"] \
  [--manifest-name "$MEDIA_DB_MANIFEST_NAME"] \
  [--db-version "$MEDIA_DB_VERSION"]
```

Automatic skip behavior:
- Adds `--skip-icons` if `icon.db` is missing.
- Adds `--skip-metadata` if `titles.US.en.json` is missing.
- Manifest generation is skipped when either `titles.pack` or `icons.pack` is not produced.

If `MEDIA_DB_MANIFEST_BASE_URL` is empty, manifest URLs are relative file names (`titles.pack`, `icons.pack`).

Metadata exporter includes only meaningful rows (at least one of: `name`, `publisher`, `intro`, `description`, `size`, `version`, `releaseDate`, `isDemo`).

## Manual Pack Export

From repo root:

```bash
python scripts/export_offline_db.py --source-dir artefacts --output-dir artefacts
```

Release-oriented example:

```bash
python scripts/export_offline_db.py \
  --source-dir artefacts \
  --output-dir release/offline_db \
  --manifest-base-url https://github.com/<owner>/<repo>/releases/latest/download \
  --db-version 20260211213000 \
  --manifest-name offline_db_manifest.json
```

Supported options:

```text
--source-dir <dir>      Discover icon DB and titles JSON in a directory
--icon-db <path>        Explicit icon DB path
--titles-json <path>    Explicit titles JSON path
--output-dir <dir>      Output directory (default: ./offline_db)
--skip-icons            Export metadata pack only
--skip-metadata         Export icons pack only
--manifest-base-url <url>  Base URL prefix for manifest file URLs
--manifest-name <name>      Manifest file name (default: offline_db_manifest.json)
--db-version <value>        Manifest db_version (default: UTC timestamp)
```

## PowerShell Release Helper

Use `build_offline_db.ps1` to export packs and manifest into `release/offline_db`:

```powershell
.\build_offline_db.ps1 `
  -SourceDir "$PSScriptRoot\artefacts" `
  -OutputDir "$PSScriptRoot\release\offline_db" `
  -ManifestBaseUrl "https://github.com/<owner>/<repo>/releases/latest/download" `
  -ManifestName "offline_db_manifest.json" `
  -DbVersion "20260211213000"
```

## Manifest File

When both packs are exported, `offline_db_manifest.json` is written with this structure:

```json
{
  "schema": 1,
  "db_version": "20260211213000",
  "generated_at_utc": "2026-02-11T21:30:00Z",
  "files": {
    "titles.pack": {
      "url": "https://github.com/<owner>/<repo>/releases/latest/download/titles.pack",
      "size": 0,
      "sha256": "<sha256>"
    },
    "icons.pack": {
      "url": "https://github.com/<owner>/<repo>/releases/latest/download/icons.pack",
      "size": 0,
      "sha256": "<sha256>"
    }
  }
}
```

## Progress and Summary Files

Title files:
- `titles.progress.json` and `titles.summary.json` are final snapshots for title update checks.
- Include source hashes, rebuild reason, and title diff counters.
- In `MEDIA_DB_CHECK_UPDATES_ONLY=1`, these are the only summary/progress files updated during that run.

Icon/Banner files:
- `*.progress.json` updates during processing.
- `*.summary.json` is the final completed snapshot.
- Key metrics: `to_process`, `skipped_unchanged`, `new_rows`, `updated_rows`, `removed_rows`, `ok`, `failed`, `db_rows`.

## Reset and Clean Rebuild

- `MEDIA_DB_RESET=1` removes selected media DB files before rebuild.
- `MEDIA_DB_RESET=1` does not remove `nut/titledb` history or title hash cache.
- For fully clean state, delete `nut/` and rerun `docker compose up --build`.

## Common Patterns

- Daily incremental run: `docker compose up`.
- Metadata monitoring only: `MEDIA_DB_CHECK_UPDATES_ONLY=1 docker compose up`.
- Full refresh for selected mode: `MEDIA_DB_RESET=1 MEDIA_DB_MODE=<icons|banners|both> docker compose up`.
- Release-ready manifest URLs: `MEDIA_DB_MANIFEST_BASE_URL=https://github.com/<owner>/<repo>/releases/latest/download docker compose up`.
- Debug build without packs: `MEDIA_DB_EXPORT_PACKS=0 docker compose up`.

## Troubleshooting

### Docker engine unavailable

Symptom (Windows):
- `open //./pipe/dockerDesktopLinuxEngine: Access is denied`

Fix:
- Start Docker Desktop and wait for engine readiness.
- Run `docker compose up` again.

### `env: 'bash\r': No such file or directory`

Cause:
- `scripts/build_media_db.sh` has CRLF line endings.

Fix:
- Convert file to LF.
- Rebuild/restart container.

### Packs or manifest not generated

Check:
- `MEDIA_DB_EXPORT_PACKS=1`
- `MEDIA_DB_CHECK_UPDATES_ONLY=0`
- Required inputs exist in `artefacts/` (`titles.US.en.json`, `icon.db`).
- `offline_db_manifest.json` is only generated when both `titles.pack` and `icons.pack` are exported in the same run.

### `icons.pack` missing in banners-only runs

Expected when `icon.db` has not been built yet.

Fix:
- Run at least one icons build: `MEDIA_DB_MODE=icons docker compose up`.

## Local Utility

Interactive DB inspection:

```bash
python scripts/db_browser.py
```
