#!/bin/zsh
# Build Moku.app from a frozen copy of app/ and assets/ (build/snapshot), so edits in progress can't
# break the build halfway ("input file was modified during the build"). The copy keeps its own
# .build, so later snapshots rebuild only what changed.
set -euo pipefail
root=${0:A:h:h}
snap="$root/build/snapshot"
mkdir -p "$snap"
# Review movies stay out; pictures the app bundles (Resources/, like the welcome's peek-<companion>.png) come along.
rsync -a --delete --exclude .build --exclude screenshots --include 'Resources/*.mp4' --exclude '*.mp4' "$root/app/" "$snap/app/"
# rsync keeps folder times, so SwiftPM wouldn't notice added source files; make it re-plan.
touch "$snap"/app/*/Package.swift
rsync -a --delete --exclude previews/anim-v2 --exclude reports --exclude src "$root/assets/" "$snap/assets/"
mkdir -p "$snap/assets/previews" && rsync -a "$root/assets/previews/"stage_*.png "$snap/assets/previews/"
MOKU_APP_SOURCE="$snap/app" MOKU_ASSETS_DIR="$snap/assets" "$root/scripts/build-app.sh" "${1:-release}"
