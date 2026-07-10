#!/usr/bin/env bash
set -euo pipefail

# Re-apply the local x-statsig-id patch after source updates, rebuild the
# patched image, stop any existing grok2api container, start with Compose,
# then print credentials.
# This intentionally refuses WARP/anti-ban or Cloudflare-bypass Compose files.

DEPLOY_DIR="${DEPLOY_DIR:-/opt/grok2api}"
IMAGE_NAME="${IMAGE_NAME:-grok2api:patched}"
HOST_PORT="${HOST_PORT:-8000}"
CONTAINER_PORT="${CONTAINER_PORT:-8000}"
RUN_ENV="${RUN_ENV:-$DEPLOY_DIR/run.env}"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-$DEPLOY_DIR/credentials.txt}"
MANAGED_COMPOSE_FILE="${MANAGED_COMPOSE_FILE:-$DEPLOY_DIR/compose.yml}"
COMPOSE_FILE="${COMPOSE_FILE:-$MANAGED_COMPOSE_FILE}"

usage() {
  cat <<EOF
Usage: $0 [-f compose.yml] [--project-dir /path/to/grok2api]

Options:
  -f, --compose-file PATH   Compose file to start. Default: $MANAGED_COMPOSE_FILE
  --project-dir PATH        grok2api source directory. Can also use PROJECT_DIR env.
  -h, --help                Show this help.

The selected Compose file must not include WARP/FlareSolverr bypass services.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--compose-file)
        [[ $# -ge 2 ]] || { printf '%s requires a path\n' "$1" >&2; exit 1; }
        COMPOSE_FILE="$2"
        shift 2
        ;;
      --project-dir)
        [[ $# -ge 2 ]] || { printf '%s requires a path\n' "$1" >&2; exit 1; }
        PROJECT_DIR="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'Unknown argument: %s\n\n' "$1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

find_project_dir() {
  if [[ -n "${PROJECT_DIR:-}" && -f "$PROJECT_DIR/app/dataplane/proxy/adapters/headers.py" ]]; then
    printf '%s\n' "$PROJECT_DIR"
    return 0
  fi

  local candidates=(
    "$PWD"
    "$PWD/grok2api-main/grok2api-main"
    "$PWD/grok2api/grok2api-main/grok2api-main"
    "$DEPLOY_DIR/src"
  )
  local cand
  for cand in "${candidates[@]}"; do
    if [[ -f "$cand/app/dataplane/proxy/adapters/headers.py" ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done

  printf 'Cannot find grok2api source. Set PROJECT_DIR=/path/to/grok2api source.\n' >&2
  return 1
}

rand_secret() {
  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
}

env_value() {
  local key="$1"
  [[ -f "$RUN_ENV" ]] || return 0
  awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$RUN_ENV"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'Missing command: %s\n' "$cmd" >&2
    exit 1
  fi
}

patch_source() {
  local project_dir="$1"
  local headers="$project_dir/app/dataplane/proxy/adapters/headers.py"
  local defaults="$project_dir/config.defaults.toml"

  python3 - "$headers" "$defaults" <<'PY'
from pathlib import Path
import re
import sys

headers = Path(sys.argv[1])
defaults = Path(sys.argv[2])

text = headers.read_text(encoding="utf-8")
if "features.statsig_id" not in text:
    needle = "def _statsig_id() -> str:\n    cfg = get_config()\n"
    insert = """def _statsig_id() -> str:
    cfg = get_config()
    configured = _sanitize(
        cfg.get_str("features.statsig_id", "") if hasattr(cfg, "get_str") else "",
        field="x-statsig-id",
        strip_spaces=True,
    )
    if configured:
        return configured
"""
    if needle not in text:
        raise SystemExit("Cannot patch headers.py: _statsig_id layout changed")
    text = text.replace(needle, insert, 1)
    headers.write_text(text, encoding="utf-8", newline="\n")

cfg = defaults.read_text(encoding="utf-8")
cfg = re.sub(r"(?m)^dynamic_statsig\s*=\s*true\s*$", "dynamic_statsig = false", cfg)
cfg = re.sub(r"(?m)^dynamic_statsig\s*=\s*false\s*$", "dynamic_statsig = false", cfg)
if not re.search(r"(?m)^statsig_id\s*=", cfg):
    cfg = re.sub(
        r"(?m)^(dynamic_statsig\s*=\s*false\s*)$",
        r"\1\n# Fixed x-statsig-id captured from a real browser session. Leave blank to use the built-in fallback.\nstatsig_id = \"\"",
        cfg,
        count=1,
    )
defaults.write_text(cfg, encoding="utf-8", newline="\n")
PY

  if [[ -f "$DEPLOY_DIR/data/config.toml" ]]; then
    python3 - "$DEPLOY_DIR/data/config.toml" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
cfg = path.read_text(encoding="utf-8")
cfg = re.sub(r"(?m)^dynamic_statsig\s*=\s*true\s*$", "dynamic_statsig = false", cfg)
if not re.search(r"(?m)^statsig_id\s*=", cfg):
    cfg = re.sub(
        r"(?m)^(dynamic_statsig\s*=\s*false\s*)$",
        r"\1\nstatsig_id = \"\"",
        cfg,
        count=1,
    )
path.write_text(cfg, encoding="utf-8", newline="\n")
PY
  fi

  if [[ -d "$project_dir/scripts" ]]; then
    find "$project_dir/scripts" -type f -name '*.sh' -print0 | xargs -0 -r sed -i 's/\r$//'
  fi
  sed -i 's/\r$//' "$project_dir/Dockerfile" "$defaults" "$headers"
}

write_env_and_credentials() {
  mkdir -p "$DEPLOY_DIR/data" "$DEPLOY_DIR/logs"
  umask 077

  local app_key api_key statsig_id
  app_key="$(env_value GROK_APP_APP_KEY)"
  api_key="$(env_value GROK_APP_API_KEY)"
  statsig_id="$(env_value GROK_FEATURES_STATSIG_ID)"
  [[ -n "$app_key" ]] || app_key="$(rand_secret)"
  [[ -n "$api_key" ]] || api_key="$(rand_secret)"
  [[ -n "$statsig_id" ]] || statsig_id=""

  cat > "$RUN_ENV" <<EOF
TZ=Asia/Shanghai
LOG_LEVEL=INFO
SERVER_HOST=0.0.0.0
SERVER_PORT=$CONTAINER_PORT
SERVER_WORKERS=1
DATA_DIR=/app/data
LOG_DIR=/app/logs
ACCOUNT_STORAGE=local
ACCOUNT_LOCAL_PATH=/app/data/accounts.db
GROK_APP_APP_KEY=$app_key
GROK_APP_API_KEY=$api_key
GROK_APP_APP_URL=
GROK_FEATURES_STATSIG_ID=$statsig_id
GROK_FEATURES_DYNAMIC_STATSIG=false
GROK_PROXY_CLEARANCE_MODE=none
EOF

  cat > "$CREDENTIALS_FILE" <<EOF
Admin URL: http://$(hostname -I | awk '{print $1}'):$HOST_PORT/admin/login
API Base: http://$(hostname -I | awk '{print $1}'):$HOST_PORT/v1
Admin password: $app_key
API Key: $api_key
EOF
}

write_compose_file() {
  cat > "$MANAGED_COMPOSE_FILE" <<EOF
services:
  grok2api:
    container_name: grok2api
    image: $IMAGE_NAME
    env_file:
      - $RUN_ENV
    ports:
      - "$HOST_PORT:$CONTAINER_PORT"
    volumes:
      - $DEPLOY_DIR/data:/app/data
      - $DEPLOY_DIR/logs:/app/logs
    restart: unless-stopped
EOF
}

resolve_compose_file() {
  local project_dir="$1"
  local file="$2"

  if [[ "$file" != /* ]]; then
    if [[ -f "$PWD/$file" ]]; then
      file="$PWD/$file"
    elif [[ -f "$project_dir/$file" ]]; then
      file="$project_dir/$file"
    elif [[ -f "$DEPLOY_DIR/$file" ]]; then
      file="$DEPLOY_DIR/$file"
    fi
  fi

  if [[ ! -f "$file" ]]; then
    printf 'Compose file not found: %s\n' "$file" >&2
    exit 1
  fi

  python3 - "$file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
print(path.resolve())
PY
}

validate_compose_file() {
  local file="$1"
  python3 - "$file" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
lines = []
for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
    if line.lstrip().startswith("#"):
        continue
    lines.append(line)
text = "\n".join(lines)
blocked = [
    r"\bwarp\b",
    r"caomingjun/warp",
    r"\bflaresolverr\b",
    r"FLARESOLVERR",
    r"CF_REFRESH",
    r"CF_TIMEOUT",
]
for pattern in blocked:
    if re.search(pattern, text, re.IGNORECASE):
        raise SystemExit(
            f"Refusing Compose file {path}: contains blocked bypass component matching {pattern!r}"
        )
PY
}

stop_existing_service() {
  local selected_compose="$1"

  printf 'Stopping existing Compose service if present\n'
  if [[ -f "$MANAGED_COMPOSE_FILE" ]]; then
    docker compose -f "$MANAGED_COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true
  fi
  if [[ "$selected_compose" != "$MANAGED_COMPOSE_FILE" ]]; then
    docker compose -f "$selected_compose" down --remove-orphans >/dev/null 2>&1 || true
  fi

  if docker ps -a --format '{{.Names}}' | grep -qx 'grok2api'; then
    docker rm -f grok2api >/dev/null
  fi
}

main() {
  parse_args "$@"

  require_cmd docker
  require_cmd python3
  docker compose version >/dev/null

  local project_dir
  project_dir="$(find_project_dir)"
  printf 'Using source: %s\n' "$project_dir"

  patch_source "$project_dir"
  write_env_and_credentials
  write_compose_file
  COMPOSE_FILE="$(resolve_compose_file "$project_dir" "$COMPOSE_FILE")"
  validate_compose_file "$COMPOSE_FILE"

  printf 'Building image: %s\n' "$IMAGE_NAME"
  docker build -t "$IMAGE_NAME" "$project_dir"

  stop_existing_service "$COMPOSE_FILE"

  printf 'Starting service with Compose: %s\n' "$COMPOSE_FILE"
  docker compose -f "$COMPOSE_FILE" up -d

  printf 'Waiting for health check'
  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:$HOST_PORT/health" >/dev/null 2>&1; then
      printf '\n'
      break
    fi
    printf '.'
    sleep 2
  done

  docker compose -f "$COMPOSE_FILE" ps
  printf '\nCredentials:\n'
  cat "$CREDENTIALS_FILE"
}

main "$@"
