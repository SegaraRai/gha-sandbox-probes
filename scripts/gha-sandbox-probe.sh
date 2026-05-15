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

is_hard_blocked_env_name() {
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
    *)
      return 1
      ;;
  esac
}

is_sensitive_env_name() {
  case "${1^^}" in
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

normalize_check_name() {
  local name="${1,,}"
  name="${name//_/-}"

  case "$name" in
    container | require-container)
      printf 'container-marker'
      ;;
    cap | caps | capability | capabilities | zero-caps | require-zero-caps)
      printf 'zero-capabilities'
      ;;
    env | environment | environment-variables)
      printf 'environment'
      ;;
    credentials | credential-files)
      printf 'credential-files'
      ;;
    metadata | cloud-metadata)
      printf 'cloud-metadata'
      ;;
    aws-metadata | metadata-aws)
      printf 'cloud-metadata-aws'
      ;;
    azure-metadata | metadata-azure)
      printf 'cloud-metadata-azure'
      ;;
    gcp-metadata | google-metadata | metadata-gcp | metadata-google)
      printf 'cloud-metadata-gcp'
      ;;
    readonly | read-only | readonly-path | readonly-paths | read-only-paths)
      printf 'readonly-paths'
      ;;
    *)
      printf '%s' "$name"
      ;;
  esac
}

is_check_disabled() {
  local expected disabled_check disabled_checks normalized
  expected="$(normalize_check_name "$1")"
  disabled_checks="${GHA_SANDBOX_DISABLE_CHECKS:-}"
  disabled_checks="${disabled_checks//,/ }"

  for disabled_check in $disabled_checks; do
    [ -n "$disabled_check" ] || continue
    normalized="$(normalize_check_name "$disabled_check")"

    case "$normalized:$expected" in
      all-risk-accepted:* | \
      "$expected:$expected" | \
      cloud-metadata:cloud-metadata-aws | \
      cloud-metadata:cloud-metadata-azure | \
      cloud-metadata:cloud-metadata-gcp)
        return 0
        ;;
    esac
  done

  return 1
}

run_risk_accepted_check() {
  local check_name="$1"
  shift

  if is_check_disabled "$check_name"; then
    notice "Sandbox probe check disabled by explicit risk acceptance: $(normalize_check_name "$check_name")"
    return
  fi

  "$@"
}

is_allowed_env_name() {
  local expected="$1"
  local allowed_names="${GHA_SANDBOX_ALLOWED_ENV_NAMES:-${SANDBOX_ALLOWED_ENV_NAMES:-}}"
  local name

  allowed_names="${allowed_names//,/ }"

  for name in $allowed_names; do
    if [ "$name" = "$expected" ]; then
      return 0
    fi
  done

  return 1
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
  if [ -f /.dockerenv ]; then
    return
  fi

  if grep -Eiq '/(docker|kubepods|containerd|podman)(/|[-:])' /proc/1/cgroup 2>/dev/null; then
    return
  fi

  error "No container marker was detected"
}

require_zero_capabilities() {
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
  if is_check_disabled environment; then
    notice "Sandbox probe check disabled by explicit risk acceptance: environment"
    return
  fi

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
    if [ -n "$value" ] && ! is_allowed_env_name "$key"; then
      error "Sensitive CI credential environment variable is visible: $key"
    fi
  done

  while IFS='=' read -r key value; do
    if is_allowed_env_name "$key"; then
      continue
    fi

    if is_hard_blocked_env_name "$key"; then
      continue
    fi

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
  if is_check_disabled credential-files; then
    notice "Sandbox probe check disabled by explicit risk acceptance: credential-files"
    return
  fi

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
  local aws_token token_response response response_body

  if is_check_disabled cloud-metadata-aws; then
    notice "Sandbox probe check disabled by explicit risk acceptance: cloud-metadata-aws"
  else
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
  fi

  if is_check_disabled cloud-metadata-azure; then
    notice "Sandbox probe check disabled by explicit risk acceptance: cloud-metadata-azure"
  else
    response="$(metadata_response GET 169.254.169.254 '/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F' 'Metadata: true')"
    if grep -Eiq '"access_token"[[:space:]]*:' <<< "$response"; then
      error "Azure managed identity token appears reachable from inside the sandbox"
    fi
  fi

  if is_check_disabled cloud-metadata-gcp; then
    notice "Sandbox probe check disabled by explicit risk acceptance: cloud-metadata-gcp"
  else
    response="$(metadata_response GET metadata.google.internal /computeMetadata/v1/instance/service-accounts/default/token 'Metadata-Flavor: Google')"
    if grep -Eiq '"access_token"[[:space:]]*:' <<< "$response"; then
      error "Google Cloud service account token appears reachable from inside the sandbox"
    fi
  fi
}

deny_writable_readonly_paths() {
  if is_check_disabled readonly-paths; then
    notice "Sandbox probe check disabled by explicit risk acceptance: readonly-paths"
    return
  fi

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
  if [ "${GHA_SANDBOX_REQUIRE_CONTAINER:-1}" = "0" ]; then
    GHA_SANDBOX_DISABLE_CHECKS="${GHA_SANDBOX_DISABLE_CHECKS:-} container-marker"
  fi
  if [ "${GHA_SANDBOX_REQUIRE_ZERO_CAPS:-1}" = "0" ]; then
    GHA_SANDBOX_DISABLE_CHECKS="${GHA_SANDBOX_DISABLE_CHECKS:-} zero-capabilities"
  fi
  if [ "${GHA_SANDBOX_CHECK_METADATA:-1}" = "0" ]; then
    GHA_SANDBOX_DISABLE_CHECKS="${GHA_SANDBOX_DISABLE_CHECKS:-} cloud-metadata"
  fi

  run_risk_accepted_check container-marker require_container_marker
  run_risk_accepted_check zero-capabilities require_zero_capabilities
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
