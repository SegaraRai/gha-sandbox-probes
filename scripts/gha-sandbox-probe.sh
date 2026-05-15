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

is_sensitive_env_name() {
  case "${1^^}" in
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
    TOKEN | \
    TOKEN_* | \
    *_TOKEN | \
    *_TOKEN_* | \
    *AUTH_TOKEN* | \
    *SECRET* | \
    *PASSWORD* | \
    *PASSWD* | \
    *_PASS | \
    *PRIVATE_KEY* | \
    *ACCESS_KEY* | \
    *API_KEY* | \
    *CREDENTIAL* | \
    *COOKIE* | \
    *_SESSION_TOKEN | \
    *_SESSION_COOKIE)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

has_url_credentials() {
  [[ "$1" =~ ://[^/@]+@ ]]
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
  local socket_paths=(
    /var/run/docker.sock
    /run/docker.sock
    /var/run/containerd/containerd.sock
    /run/containerd/containerd.sock
    /var/run/podman/podman.sock
    /run/podman/podman.sock
    /var/run/crio/crio.sock
    /run/crio/crio.sock
    /var/run/buildkit/buildkitd.sock
    /run/buildkit/buildkitd.sock
  )

  for socket_path in "${socket_paths[@]}"; do
    if [ -S "$socket_path" ]; then
      error "Container runtime socket is visible inside the sandbox: $socket_path"
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

  while IFS='=' read -r key value; do
    if is_sensitive_env_name "$key"; then
      error "Potentially sensitive environment variable is visible: $key"
    fi

    if has_url_credentials "$value"; then
      error "Environment variable contains URL credentials: $key"
    fi
  done < <(env)
}

deny_host_runner_process_visibility() {
  local cmdline pid command environ mem
  local patterns=(
    Runner.Worker
    Runner.Listener
    Runner.PluginHost
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
          environ="/proc/$pid/environ"
          mem="/proc/$pid/mem"

          if [ -r "$environ" ]; then
            error "Host runner process environment is readable inside the sandbox: $environ"
          fi

          if [ -r "$mem" ]; then
            error "Host runner process memory is readable inside the sandbox: $mem"
          fi
          ;;
      esac
    done
  done
}

file_has_secret_marker() {
  local path="$1"

  [ -r "$path" ] || return 1

  grep -Eiq \
    '(_authToken|_auth[[:space:]]*=|token[[:space:]]*=|password[[:space:]]*=|passwd[[:space:]]*=|secret[[:space:]]*=|credential|aws_access_key_id|aws_secret_access_key|session_token|refresh_token|client_secret|identitytoken|BEGIN [A-Z ]*PRIVATE KEY|machine[[:space:]]+github\.com|oauth|bearer)' \
    "$path" 2>/dev/null
}

deny_credential_files() {
  local path home real_path seen_token_paths

  local service_account_tokens=(
    /var/run/secrets/kubernetes.io/serviceaccount/token
    /run/secrets/kubernetes.io/serviceaccount/token
    /var/run/secrets/eks.amazonaws.com/serviceaccount/token
  )

  seen_token_paths=":"
  for path in "${service_account_tokens[@]}"; do
    real_path="$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")"
    case "$seen_token_paths" in
      *":$real_path:"*)
        continue
        ;;
    esac
    seen_token_paths="$seen_token_paths$real_path:"

    if [ -s "$path" ] && [ -r "$path" ]; then
      error "Kubernetes service account token is readable inside the sandbox: $path"
    fi
  done

  home="${HOME:-}"
  [ -n "$home" ] || return

  local credential_files=(
    "$home/.aws/credentials"
    "$home/.aws/config"
    "$home/.azure/accessTokens.json"
    "$home/.config/gcloud/application_default_credentials.json"
    "$home/.config/gcloud/credentials.db"
    "$home/.docker/config.json"
    "$home/.kube/config"
    "$home/.netrc"
    "$home/.npmrc"
    "$home/.pypirc"
    "$home/.cargo/credentials"
    "$home/.cargo/credentials.toml"
    "$home/.gem/credentials"
    "$home/.git-credentials"
    "$home/.config/gh/hosts.yml"
    "$home/.vault-token"
    "$home/.ssh/id_dsa"
    "$home/.ssh/id_ecdsa"
    "$home/.ssh/id_ed25519"
    "$home/.ssh/id_rsa"
  )

  for path in "${credential_files[@]}"; do
    if [ -f "$path" ] && file_has_secret_marker "$path"; then
      error "Credential-bearing file is readable inside the sandbox: $path"
    fi
  done
}

metadata_response() {
  local method="$1"
  local host="$2"
  local path="$3"
  local headers="${4:-}"

  if command -v curl >/dev/null 2>&1; then
    local curl_args=(-sS --connect-timeout 1 --max-time 2 -D - -X "$method")
    if [ -n "$headers" ]; then
      curl_args+=(-H "$headers")
    fi

    curl "${curl_args[@]}" "http://$host$path" -o - 2>/dev/null || true
    return
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout 2 bash -c '
      host="$1"
      path="$2"
      method="$3"
      headers="$4"
      exec 3<>"/dev/tcp/${host}/80" || exit 0
      printf "%s %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n" "$method" "$path" "$host" >&3
      if [ -n "$headers" ]; then
        printf "%s\r\n" "$headers" >&3
      fi
      printf "\r\n" >&3
      head -c 4096 <&3 || true
    ' _ "$host" "$path" "$method" "$headers" 2>/dev/null || true
  fi
}

http_body() {
  awk 'body { print } /^\r?$/ { body = 1 }' | tr -d '\r'
}

deny_cloud_metadata_access() {
  if [ "${GHA_SANDBOX_CHECK_METADATA:-1}" = "0" ]; then
    return
  fi

  local aws_token token_response response response_body

  token_response="$(metadata_response PUT 169.254.169.254 /latest/api/token 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
  if grep -Eiq 'HTTP/[0-9.]+ 200' <<< "$token_response"; then
    aws_token="$(http_body <<< "$token_response" | head -n 1)"
  else
    aws_token=""
  fi

  if [ -n "$aws_token" ]; then
    response="$(metadata_response GET 169.254.169.254 /latest/meta-data/iam/security-credentials/ "X-aws-ec2-metadata-token: $aws_token")"
  else
    response="$(metadata_response GET 169.254.169.254 /latest/meta-data/iam/security-credentials/)"
  fi
  response_body="$(http_body <<< "$response")"
  if grep -Eiq 'HTTP/[0-9.]+ 200' <<< "$response" && [ -n "$response_body" ]; then
    error "AWS metadata credentials appear reachable from inside the sandbox"
  fi

  response="$(metadata_response GET 169.254.169.254 '/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F' 'Metadata: true')"
  if grep -Eiq '"access_token"[[:space:]]*:' <<< "$response"; then
    error "Azure managed identity token appears reachable from inside the sandbox"
  fi

  response="$(metadata_response GET metadata.google.internal /computeMetadata/v1/instance/service-accounts/default/token 'Metadata-Flavor: Google')"
  if grep -Eiq '"access_token"[[:space:]]*:' <<< "$response"; then
    error "Google Cloud service account token appears reachable from inside the sandbox"
  fi
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
  deny_credential_files
  deny_cloud_metadata_access
  deny_writable_readonly_paths

  if [ "$failures" -ne 0 ]; then
    error "Sandbox probe failed with $failures finding(s)"
    exit 1
  fi

  notice "Sandbox probe passed"
}

main "$@"
