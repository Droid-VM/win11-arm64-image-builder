#!/usr/bin/env bash
# =====================================================================
# common.sh — 檔案類輸入的統一解析（給 build.sh source）。
#   規則：URL -> 下載到 files/ 再使用；本地路徑 -> 直接使用。
#   zip 的解壓縮屬「使用檔案」的內部流程（也放在 files/），與是不是 URL 無關。
# 需要呼叫端先設好 $HERE（macos/）。中間檔+快取都放 $FILES = macos/files。
# =====================================================================
FILES="${FILES:-$HERE/files}"

# resolve_file <url-or-path> [save-as]
#   URL  -> 下載到 files/<save-as>（save-as 省略則取 URL 檔名），回傳該路徑
#   路徑 -> 原樣回傳（需存在）
resolve_file() {
  local src="$1" name="${2:-}"
  case "$src" in
    http://*|https://*)
      [ -n "$name" ] || name="$(basename "${src%%\?*}")"
      mkdir -p "$FILES"
      local dst="$FILES/$name"
      if [ -f "$dst" ]; then
        echo "[files] 已存在，略過下載: $dst" >&2
      else
        echo "[files] 下載 $src -> $dst" >&2
        curl -fL "$src" -o "$dst.part" && mv "$dst.part" "$dst"
      fi
      printf '%s\n' "$dst" ;;
    *)
      [ -e "$src" ] || { echo "[files] 找不到: $src" >&2; return 1; }
      printf '%s\n' "$src" ;;
  esac
}

# resolve_dir <path>
#   資料夾 -> 原樣回傳；zip -> 解壓到 files/<stem>/ 再回傳該資料夾（不重覆解壓）
resolve_dir() {
  local p="$1"
  if [ -d "$p" ]; then printf '%s\n' "$p"; return 0; fi
  case "$p" in
    *.zip)
      local stem out
      stem="$(basename "$p" .zip)"
      out="$FILES/$stem"
      if [ ! -d "$out" ] || [ -z "$(ls -A "$out" 2>/dev/null)" ]; then
        echo "[files] 解壓 $p -> $out" >&2
        mkdir -p "$out"; unzip -q -o "$p" -d "$out"
      fi
      printf '%s\n' "$out" ;;
    *)
      echo "[files] 不是資料夾也不是 zip: $p" >&2; return 1 ;;
  esac
}
