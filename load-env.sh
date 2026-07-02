# load-env.sh — sourced by each script to load the .env at the project root.
# Rule: existing environment variables / CLI overrides take priority; .env only fills in unset values.
# Requires: the caller defines ROOT (project root) first. Format: KEY=value (# starts a comment, values may be quoted).
__envfile="${ROOT:-.}/.env"
if [ -f "$__envfile" ]; then
  while IFS= read -r __line || [ -n "$__line" ]; do
    __line="${__line%$'\r'}"                       # strip Windows CR
    case "$__line" in ''|\#*) continue;; *=*) ;; *) continue;; esac
    __k="${__line%%=*}"; __v="${__line#*=}"
    __k="$(printf '%s' "$__k" | tr -d '[:space:]')"  # strip whitespace around key
    [ -z "$__k" ] && continue
    case "$__v" in                                  # strip outer quotes from value
      \"*\") __v="${__v#\"}"; __v="${__v%\"}";;
      \'*\') __v="${__v#\'}"; __v="${__v%\'}";;
    esac
    if eval "[ -z \"\${$__k+x}\" ]"; then export "$__k=$__v"; fi
  done < "$__envfile"
  unset __line __k __v
fi
unset __envfile
