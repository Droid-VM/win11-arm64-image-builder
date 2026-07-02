#!/usr/bin/env bash
# =====================================================================
# common.sh — unified resolution of file-type inputs (sourced by build.sh).
#   Rule: URL -> download into files/ then use; local path -> use directly.
#   Unzipping is part of the internal "use the file" flow (also placed in files/), regardless of whether it is a URL.
# The caller must set $HERE (macos/) first. Intermediate files + cache all go in $FILES = macos/files.
# =====================================================================
FILES="${FILES:-$HERE/files}"

# resolve_file <url-or-path> [save-as]
#   URL  -> download into files/<save-as> (if save-as is omitted, take the URL filename), return that path
#   path -> return as-is (must exist)
resolve_file() {
  local src="$1" name="${2:-}"
  case "$src" in
    http://*|https://*)
      [ -n "$name" ] || name="$(basename "${src%%\?*}")"
      mkdir -p "$FILES"
      local dst="$FILES/$name"
      if [ -f "$dst" ]; then
        echo "[files] already exists, skipping download: $dst" >&2
      else
        echo "[files] downloading $src -> $dst" >&2
        curl -fL "$src" -o "$dst.part" && mv "$dst.part" "$dst"
      fi
      printf '%s\n' "$dst" ;;
    *)
      [ -e "$src" ] || { echo "[files] not found: $src" >&2; return 1; }
      printf '%s\n' "$src" ;;
  esac
}

# resolve_dir <path>
#   folder -> return as-is; zip -> extract into files/<stem>/ then return that folder (does not re-extract)
resolve_dir() {
  local p="$1"
  if [ -d "$p" ]; then printf '%s\n' "$p"; return 0; fi
  case "$p" in
    *.zip)
      local stem out
      stem="$(basename "$p" .zip)"
      out="$FILES/$stem"
      if [ ! -d "$out" ] || [ -z "$(ls -A "$out" 2>/dev/null)" ]; then
        echo "[files] extracting $p -> $out" >&2
        mkdir -p "$out"; unzip -q -o "$p" -d "$out"
      fi
      printf '%s\n' "$out" ;;
    *)
      echo "[files] not a folder and not a zip: $p" >&2; return 1 ;;
  esac
}
