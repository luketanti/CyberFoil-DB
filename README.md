# CyberFoil-DB
Contains db files for icons, banners and title info.

## Build locally with Docker Compose

Run:

```bash
docker compose up --build
```

The image now pre-installs Python dependencies, so after the initial image build, subsequent runs start the DB build immediately.

Build mode can be selected at runtime:

```bash
# default: builds both
docker compose up

# build only icon.db
MEDIA_DB_MODE=icons docker compose up

# build only banners.db
MEDIA_DB_MODE=banners docker compose up
```

Resume behavior:
- Existing `nut/build_artefacts/icon.db` and `nut/build_artefacts/banners.db` are reused.
- Unchanged records are skipped; only new/changed URLs are processed.
- If interrupted, running again continues from the existing DB content.

Live progress files (updated during run):
- `artefacts/icon.progress.json`
- `artefacts/banner.progress.json`
- `artefacts/icon.summary.json` (final summary)
- `artefacts/banner.summary.json` (final summary)

Force a full rebuild from scratch:

```bash
MEDIA_DB_RESET=1 docker compose up
```

PowerShell examples:

```powershell
$env:MEDIA_DB_MODE="icons"; docker compose up
$env:MEDIA_DB_MODE="banners"; docker compose up
$env:MEDIA_DB_RESET="1"; docker compose up
```

## Browse DB interactively

Run from repo root:

```bash
python scripts/db_browser.py
```

It provides options to:
- show DB info (row count, total image bytes, DB file size)
- search entries by game name (using `titles.US.en.json`)
- extract an image file after search by selecting a result number
- switch between DB files (e.g. icon.db / banners.db)

If you change the Dockerfile or want to refresh baked dependencies, force a clean rebuild:

```bash
docker compose build --no-cache
docker compose up
```

Generated files will be available in:

`artefacts/titles.US.en.json`  
`artefacts/icon.db`  
`artefacts/banners.db`
