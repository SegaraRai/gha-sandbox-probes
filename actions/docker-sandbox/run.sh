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
setup="${INPUT_SETUP:-none}"
env_block="${INPUT_ENV:-}"

if [ ! -f "$probe_script" ]; then
  echo "::error::Probe script was not found: $probe_script"
  exit 1
fi

if [ ! -d "$workspace" ]; then
  echo "::error::Workspace path does not exist: $workspace"
  exit 1
fi

case "$setup" in
  none | vite-plus)
    ;;
  *)
    echo "::error::Unsupported setup mode: $setup"
    exit 1
    ;;
esac

case "$network" in
  bridge | host | none)
    ;;
  *)
    echo "::error::Unsupported network mode: $network"
    exit 1
    ;;
esac

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
  --env SANDBOX_SETUP="$setup"
  --volume "$workspace:/workspace:ro"
  --volume "$repo_dir/scripts:/probe-scripts:ro"
  --workdir /tmp
)

allowed_env_names=(CI TMPDIR)

while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    \#*)
      continue
      ;;
  esac

  if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
    echo "::error::Invalid environment entry: $line"
    exit 1
  fi

  allowed_env_names+=("${line%%=*}")
  docker_args+=(--env "$line")
done <<< "$env_block"

allowed_env_names_csv="$(IFS=,; echo "${allowed_env_names[*]}")"
docker_args+=(--env "SANDBOX_ALLOWED_ENV_NAMES=$allowed_env_names_csv")

docker "${docker_args[@]}" "$image" bash -euo pipefail -s <<'SANDBOX_SCRIPT'
mkdir -p "$HOME" /tmp/workspace
tar -C /workspace -cf - . | tar -C /tmp/workspace -xf -
cd /tmp/workspace

/probe-scripts/gha-sandbox-probe.sh

case "$SANDBOX_SETUP" in
  none)
    ;;
  vite-plus)
    curl -fsSL --connect-timeout 5 --max-time 15 https://viteplus.dev/install.sh | bash
    . "$HOME/.vite-plus/env"
    vp env use "$(cat .node-version)"
    vp install
    ;;
  *)
    echo "::error::Unsupported setup mode: $SANDBOX_SETUP"
    exit 1
    ;;
esac

allowed_env=(
  HOME="$HOME"
  PATH="$PATH"
  LANG="${LANG:-C.UTF-8}"
  CI="${CI:-true}"
  TMPDIR="${TMPDIR:-/tmp}"
)

IFS=',' read -r -a sandbox_allowed_names <<< "${SANDBOX_ALLOWED_ENV_NAMES:-CI,TMPDIR}"
for name in "${sandbox_allowed_names[@]}"; do
  case "$name" in
    '' | *[!A-Za-z0-9_]* | [0-9]*)
      ;;
    HOME | LANG | PATH)
      ;;
    *)
      value="${!name-}"
      allowed_env+=("$name=$value")
      ;;
  esac
done

env -i "${allowed_env[@]}" bash -lc "$SANDBOX_COMMAND"
SANDBOX_SCRIPT
