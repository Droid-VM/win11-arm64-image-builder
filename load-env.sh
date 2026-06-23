# load-env.sh — 由各腳本 source，載入專案根目錄的 .env。
# 規則：已存在的環境變數 / CLI 覆寫「優先」，.env 只補沒設定的值。
# 需求：呼叫端先定義 ROOT（專案根目錄）。格式：KEY=value（# 開頭為註解，值可加引號）。
__envfile="${ROOT:-.}/.env"
if [ -f "$__envfile" ]; then
  while IFS= read -r __line || [ -n "$__line" ]; do
    __line="${__line%$'\r'}"                       # 去掉 Windows CR
    case "$__line" in ''|\#*) continue;; *=*) ;; *) continue;; esac
    __k="${__line%%=*}"; __v="${__line#*=}"
    __k="$(printf '%s' "$__k" | tr -d '[:space:]')"  # 去掉 key 兩側空白
    [ -z "$__k" ] && continue
    case "$__v" in                                  # 去掉值外層引號
      \"*\") __v="${__v#\"}"; __v="${__v%\"}";;
      \'*\') __v="${__v#\'}"; __v="${__v%\'}";;
    esac
    if eval "[ -z \"\${$__k+x}\" ]"; then export "$__k=$__v"; fi
  done < "$__envfile"
  unset __line __k __v
fi
unset __envfile
