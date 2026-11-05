#!/usr/bin/env bash
# Copies the files that cannot be recreated to off-host storage with restic: Immich's originals (library/ and upload/),
# its profile images and its own database dumps (backups/). Thumbnails, previews and transcoded videos (thumbs/,
# encoded-video/) are made again by Immich and are left out.
# RESTIC_REPOSITORY and RESTIC_PASSWORD_FILE must be set, e.g. in the environment of the cron job.
set -euo pipefail

cd "$(dirname "$0")/.."
: "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY}"
: "${RESTIC_PASSWORD_FILE:?set RESTIC_PASSWORD_FILE}"

folders=()
for folder in library upload profile backups; do
  if [[ -d data/immich/$folder ]]; then
    folders+=("data/immich/$folder")
  fi
done
restic backup --tag spexgram "${folders[@]}"
restic forget --tag spexgram --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
