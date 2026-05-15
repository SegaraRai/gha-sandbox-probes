#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/../.." && pwd)"
probe_script="$repo_dir/scripts/gha-sandbox-probe.sh"

image="${INPUT_IMAGE:?image input is required}"
command="${INPUT_COMMAND:?command input is required}"
workspace="${INPUT_WORKSPACE:-${GITHUB_WORKSPACE:-$PWD}}"
user="${INPUT_USER:-1001}"
pids_limit="${INPUT_PIDS_LIMIT:-512}"
network="${INPUT_NETWORK:-bridge}"
env_block="${INPUT_ENV:-}"
inherit_env_block="${INPUT_INHERIT_ENV:-auto}"

if [ ! -f "$probe_script" ]; then
  echo "::error::Probe script was not found: $probe_script"
  exit 1
fi

if [ ! -d "$workspace" ]; then
  echo "::error::Workspace path does not exist: $workspace"
  exit 1
fi

case "$network" in
  bridge | host | none)
    ;;
  *)
    echo "::error::Unsupported network mode: $network"
    exit 1
    ;;
esac

is_blocked_env_name() {
  local name="${1^^}"

  case "$name" in
    ACTIONS_CACHE_SERVICE_V2 | \
    ACTIONS_CACHE_URL | \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN | \
    ACTIONS_ID_TOKEN_REQUEST_URL | \
    ACTIONS_RESULTS_URL | \
    ACTIONS_RUNTIME_TOKEN | \
    ACTIONS_RUNTIME_URL | \
    GH_TOKEN | \
    GITHUB_ENV | \
    GITHUB_OUTPUT | \
    GITHUB_PATH | \
    GITHUB_STATE | \
    GITHUB_STEP_SUMMARY | \
    GITHUB_TOKEN | \
    GIT_ASKPASS | \
    NETRC | \
    NODE_AUTH_TOKEN | \
    NPM_CONFIG_USERCONFIG | \
    NPM_TOKEN | \
    PIP_CONFIG_FILE | \
    SSH_AGENT_PID | \
    SSH_AUTH_SOCK)
      return 0
      ;;
    *TOKEN* | \
    *SECRET* | \
    *PASSWORD* | \
    *PASSWD* | \
    *PRIVATE_KEY* | \
    *ACCESS_KEY* | \
    *API_KEY* | \
    *CREDENTIAL* | \
    *COOKIE* | \
    *SESSION*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

append_env_entry() {
  local entry="$1"
  local name="${entry%%=*}"

  if [[ ! "$entry" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
    echo "::error::Invalid environment entry: $entry"
    exit 1
  fi

  if is_blocked_env_name "$name"; then
    echo "::error::Refusing to pass sensitive CI environment variable: $name"
    exit 1
  fi

  if [[ "${entry#*=}" =~ ://[^/@]+@ ]]; then
    echo "::error::Refusing to pass environment variable containing URL credentials: $name"
    exit 1
  fi

  if [ "$name" = "HOME" ]; then
    echo "::error::HOME is managed by the sandbox and cannot be overridden"
    exit 1
  fi

  allowed_env_names+=("$name")
  docker_args+=(--env "$entry")
}

append_inherited_env_name() {
  local name="$1"

  [ -n "$name" ] || return

  if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "::error::Invalid inherited environment variable name: $name"
    exit 1
  fi

  if is_blocked_env_name "$name"; then
    echo "::error::Refusing to inherit sensitive CI environment variable: $name"
    exit 1
  fi

  case "$name" in
    HOME | PATH)
      echo "::error::Refusing to inherit host-specific environment variable: $name"
      exit 1
      ;;
  esac

  allowed_env_names+=("$name")
  docker_args+=(--env "$name")
}

append_auto_env_names() {
  local safe_auto_env_names=(
    TERM
    COLORTERM
    NO_COLOR
    FORCE_COLOR
    CLICOLOR
    CLICOLOR_FORCE
    CARGO_TERM_COLOR
    CMAKE_COLOR_DIAGNOSTICS
    PY_COLORS
    PYTHON_COLORS
    LANG
    LANGUAGE
    LC_ALL
    LC_CTYPE
    LC_MESSAGES
    LC_COLLATE
    LC_NUMERIC
    LC_TIME
    LC_MONETARY
    LC_PAPER
    LC_NAME
    LC_ADDRESS
    LC_TELEPHONE
    LC_MEASUREMENT
    LC_IDENTIFICATION
    TZ
    SOURCE_DATE_EPOCH
  )

  local name
  for name in "${safe_auto_env_names[@]}"; do
    [ -n "${!name-}" ] || continue
    append_inherited_env_name "$name"
  done
}

docker_args=(
  run
  --rm
  --user "$user"
  --cap-drop=ALL
  --security-opt no-new-privileges
  --pids-limit "$pids_limit"
  --network "$network"
  --env HOME=/tmp/home
  --env CI=true
  --env TMPDIR=/tmp
  --env SANDBOX_COMMAND="$command"
  --volume "$workspace:/workspace:ro"
  --volume "$repo_dir/scripts:/probe-scripts:ro"
  --workdir /tmp
)

allowed_env_names=(CI TMPDIR)
inherit_auto_env=1

while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    \#*)
      continue
      ;;
  esac

  append_env_entry "$line"
done <<< "$env_block"

while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    \#*)
      continue
      ;;
  esac

  for name in ${line//,/ }; do
    case "${name,,}" in
      auto)
        inherit_auto_env=1
        ;;
      none)
        ;;
      *)
        append_inherited_env_name "$name"
        ;;
    esac
  done
done <<< "$inherit_env_block"

if [ "${inherit_auto_env:-0}" = "1" ]; then
  append_auto_env_names
fi

allowed_env_names_csv="$(IFS=,; echo "${allowed_env_names[*]}")"
docker_args+=(--env "SANDBOX_ALLOWED_ENV_NAMES=$allowed_env_names_csv")

docker "${docker_args[@]}" "$image" bash -euo pipefail -s <<'SANDBOX_SCRIPT'
mkdir -p "$HOME" /tmp/workspace
tar -C /workspace -cf - . | tar -C /tmp/workspace -xf -
cd /tmp/workspace

/probe-scripts/gha-sandbox-probe.sh

allowed_env=(
  HOME="$HOME"
  PATH="$PATH"
  LANG="${LANG:-C.UTF-8}"
  LC_ALL="${LC_ALL:-C.UTF-8}"
  CI="${CI:-true}"
  TMPDIR="${TMPDIR:-/tmp}"
)

IFS=',' read -r -a sandbox_allowed_names <<< "${SANDBOX_ALLOWED_ENV_NAMES:-CI,TMPDIR}"
for name in "${sandbox_allowed_names[@]}"; do
  case "$name" in
    '' | *[!A-Za-z0-9_]* | [0-9]*)
      ;;
    HOME)
      ;;
    *)
      value="${!name-}"
      allowed_env+=("$name=$value")
      ;;
  esac
done

env -i "${allowed_env[@]}" bash -lc "$SANDBOX_COMMAND"
SANDBOX_SCRIPT
