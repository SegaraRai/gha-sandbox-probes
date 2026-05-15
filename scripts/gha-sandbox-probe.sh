#!/usr/bin/env bash
set -Eeuo pipefail

failures=0

notice() {
  printf '::notice::%s\n' "$*"
}

error() {
  printf '::error::%s\n' "$*"
  failures=$((failures + 1))
}

is_zero_hex() {
  case "$1" in
    '' | *[!0]*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

require_linux_proc() {
  if [ ! -r /proc/self/status ]; then
    error "Linux /proc is not available"
  fi
}

require_container_marker() {
  if [ "${GHA_SANDBOX_REQUIRE_CONTAINER:-1}" = "0" ]; then
    return
  fi

  if [ -f /.dockerenv ]; then
    return
  fi

  if grep -Eiq '/(docker|kubepods|containerd|podman)(/|[-:])' /proc/1/cgroup 2>/dev/null; then
    return
  fi

  error "No container marker was detected"
}

require_zero_capabilities() {
  if [ "${GHA_SANDBOX_REQUIRE_ZERO_CAPS:-1}" = "0" ]; then
    return
  fi

  local cap_eff
  cap_eff="$(awk '/^CapEff:/ { print $2 }' /proc/self/status)"

  if ! is_zero_hex "$cap_eff"; then
    error "Sandbox process has effective Linux capabilities: $cap_eff"
  fi
}

deny_docker_daemon_access() {
  local socket_path
  for socket_path in /var/run/docker.sock /run/docker.sock; do
    if [ -S "$socket_path" ]; then
      error "Docker socket is visible inside the sandbox: $socket_path"
    fi
  done

  case "${DOCKER_HOST:-}" in
    '')
      ;;
    unix://*)
      socket_path="${DOCKER_HOST#unix://}"
      if [ -S "$socket_path" ]; then
        error "DOCKER_HOST points to a visible Docker socket: $DOCKER_HOST"
      else
        error "DOCKER_HOST is set inside the sandbox: $DOCKER_HOST"
      fi
      ;;
    *)
      error "DOCKER_HOST is set inside the sandbox: $DOCKER_HOST"
      ;;
  esac
}

deny_actions_runtime_credentials() {
  local key value
  local keys=(
    ACTIONS_CACHE_SERVICE_V2
    ACTIONS_CACHE_URL
    ACTIONS_ID_TOKEN_REQUEST_TOKEN
    ACTIONS_ID_TOKEN_REQUEST_URL
    ACTIONS_RESULTS_URL
    ACTIONS_RUNTIME_TOKEN
    ACTIONS_RUNTIME_URL
    GH_TOKEN
    GITHUB_ENV
    GITHUB_OUTPUT
    GITHUB_PATH
    GITHUB_STATE
    GITHUB_STEP_SUMMARY
    GITHUB_TOKEN
    GIT_ASKPASS
    NETRC
    NODE_AUTH_TOKEN
    NPM_CONFIG_USERCONFIG
    NPM_TOKEN
    PIP_CONFIG_FILE
    SSH_AGENT_PID
    SSH_AUTH_SOCK
  )

  for key in "${keys[@]}"; do
    value="${!key-}"
    if [ -n "$value" ]; then
      error "Sensitive CI credential environment variable is visible: $key"
    fi
  done

  while IFS='=' read -r key _; do
    case "${key^^}" in
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
        error "Potentially sensitive environment variable is visible: $key"
        ;;
    esac
  done < <(env)
}

deny_host_runner_process_visibility() {
  local cmdline pid command
  local patterns=(
    Runner.Worker
    Runner.Listener
    actions-runner
    runsvc.sh
  )

  for cmdline in /proc/[0-9]*/cmdline; do
    [ -r "$cmdline" ] || continue
    pid="${cmdline#/proc/}"
    pid="${pid%%/*}"
    [ "$pid" != "$$" ] || continue
    command="$(tr '\0' ' ' < "$cmdline" || true)"

    local pattern
    for pattern in "${patterns[@]}"; do
      case "$command" in
        *"$pattern"*)
          error "Host runner process is visible inside the sandbox: $command"
          return
          ;;
      esac
    done
  done
}

deny_writable_readonly_paths() {
  local path
  local paths="${GHA_SANDBOX_READONLY_PATHS:-/workspace}"

  for path in $paths; do
    if [ -e "$path" ] && [ -w "$path" ]; then
      error "Expected read-only path is writable: $path"
    fi
  done
}

main() {
  require_linux_proc
  require_container_marker
  require_zero_capabilities
  deny_docker_daemon_access
  deny_actions_runtime_credentials
  deny_host_runner_process_visibility
  deny_writable_readonly_paths

  if [ "$failures" -ne 0 ]; then
    error "Sandbox probe failed with $failures finding(s)"
    exit 1
  fi

  notice "Sandbox probe passed"
}

main "$@"
