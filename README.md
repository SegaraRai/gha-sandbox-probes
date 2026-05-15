# GitHub Actions Sandbox Probes

`gha-sandbox-probes` provides small, auditable checks for GitHub Actions jobs that
run untrusted code inside a sandbox.

The project has two entry points:

- A composite GitHub Action that starts a hardened Docker sandbox, runs the probes, and then runs a command inside a sanitized environment.
- A standalone shell script that can be pinned by commit SHA and fetched from `raw.githubusercontent.com` or vendored as a submodule.

The probes are intended to fail closed. If a job exposes runner internals, Actions runtime credentials, Docker control sockets, or unexpected process visibility, the script exits non-zero.

## Threat Model

These probes are designed for CI jobs where the payload may execute arbitrary code, such as compatibility tests against third-party dependency graphs.

The checks focus on detecting:

- GitHub Actions runtime, cache, results, and OIDC credentials in the sandbox.
- Container runtime access through Docker, containerd, Podman, CRI-O, or BuildKit sockets, plus `DOCKER_HOST`.
- Effective Linux capabilities inside the sandbox.
- Visibility of host GitHub Actions runner processes through `/proc`, including readable runner environment or memory files.
- Credential-bearing files commonly targeted by supply-chain malware, including Kubernetes service account tokens, cloud credentials, registry credentials, package-manager credentials, GitHub CLI hosts, Vault tokens, and SSH keys.
- Reachable cloud metadata credential endpoints for AWS, Azure, and Google Cloud.
- Environment variables that expose sensitive names or URL userinfo credentials.
- Writable workspace mounts when a read-only workspace is expected.

The probes are not a complete sandbox. They are runtime assertions that help verify that a separate sandboxing mechanism is actually in effect.

## Use the Action

Pin the action to a full-length commit SHA.

```yaml
- name: Run compatibility in hardened sandbox
  uses: SegaraRai/gha-sandbox-probes@0123456789abcdef0123456789abcdef01234567
  with:
    image: ubuntu:24.04
    workspace: .
    user: "1001"
    env: |
      CI=true
      TMPDIR=/tmp
    inherit-env: |
      MATRIX_CASE
    command: |
      bash .github/scripts/run-compatibility.sh "$MATRIX_CASE"
```

The action intentionally does not know how to install project dependencies. Run project-specific setup in `command`, or call a setup script that you own and pin by commit SHA.

## Use the Standalone Script

Pin the raw URL to a full-length commit SHA.

```bash
curl -fsSL \
  https://raw.githubusercontent.com/SegaraRai/gha-sandbox-probes/0123456789abcdef0123456789abcdef01234567/scripts/gha-sandbox-probe.sh \
  | bash
```

For submodules or vendored copies:

```bash
bash ./scripts/gha-sandbox-probe.sh
```

## Action Inputs

| Input         | Required | Default                   | Description                                                                                                                                                                                       |
| ------------- | -------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `image`       | yes      |                           | Docker image used for the sandbox.                                                                                                                                                                |
| `command`     | yes      |                           | Command to run after the probes pass.                                                                                                                                                             |
| `workspace`   | no       | `${{ github.workspace }}` | Host path mounted read-only at `/workspace`.                                                                                                                                                      |
| `user`        | no       | `1001`                    | Container user.                                                                                                                                                                                   |
| `pids-limit`  | no       | `512`                     | Docker process limit.                                                                                                                                                                             |
| `network`     | no       | `bridge`                  | Docker network mode. Use `none` only when the command needs no network.                                                                                                                           |
| `env`         | no       |                           | Newline-separated `KEY=value` entries passed to the sandbox command.                                                                                                                              |
| `inherit-env` | no       | `auto`                    | Newline, comma, or space separated variable names inherited from the caller environment. Include `auto` to use the curated non-sensitive default set, or `none` to disable automatic inheritance. |

## Environment Inheritance

By default, the action inherits a small allowlist of non-sensitive environment variables that preserve terminal behavior, locale, timezone, and reproducible build settings:

- Color and terminal: `TERM`, `COLORTERM`, `NO_COLOR`, `FORCE_COLOR`, `CLICOLOR`, `CLICOLOR_FORCE`
- Tool-specific color controls: `CARGO_TERM_COLOR`, `CMAKE_COLOR_DIAGNOSTICS`, `PY_COLORS`, `PYTHON_COLORS`
- Locale and timezone: `LANG`, `LANGUAGE`, `LC_*`, `TZ`
- Reproducibility: `SOURCE_DATE_EPOCH`

This list is based on public tool documentation for GitHub Actions default variables, the `NO_COLOR` convention, Node.js color environment variables, Cargo terminal color, CMake color controls, pytest/Python color controls, and Go module privacy notes.

Package registry, proxy, cloud, and private module environment variables are not inherited by default because they often contain credentials or private package names. Pass values explicitly with `env`, or inherit specific names with `inherit-env`, when you understand and accept the risk of exposing them to the sandboxed command.

Explicitly passed or inherited environment variable names are registered in `GHA_SANDBOX_ALLOWED_ENV_NAMES` before the probe runs. The probe excludes those names from environment variable name and URL-userinfo checks, but it still checks structural sandbox boundaries such as runner process visibility, container runtime sockets, credential files, metadata token endpoints, capabilities, and writable mounts.

`HOME` is always managed by the sandbox. `PATH` can be set explicitly with `env`, but it cannot be inherited from the host environment.

## Project Setup

Keep setup separate from the sandbox runner. For example, a repository can own a script such as `.github/scripts/setup-vite-plus.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

curl -fsSL --connect-timeout 5 --max-time 15 https://viteplus.dev/install.sh | bash
. "$HOME/.vite-plus/env"

if [ -f .node-version ]; then
  vp env use "$(cat .node-version)"
fi

vp install
```

Then call it from `command`:

```yaml
with:
  command: |
    bash .github/scripts/setup-vite-plus.sh
    vp run test:compat --case "$MATRIX_CASE"
```

This keeps project policy out of the generic sandbox action and makes setup
changes reviewable in the consuming repository.

## Standalone Script Environment

The script supports these optional environment variables:

- `GHA_SANDBOX_REQUIRE_CONTAINER`: defaults to `1`.
- `GHA_SANDBOX_REQUIRE_ZERO_CAPS`: defaults to `1`.
- `GHA_SANDBOX_CHECK_METADATA`: defaults to `1`.
- `GHA_SANDBOX_READONLY_PATHS`: defaults to `/workspace`.
- `GHA_SANDBOX_ALLOWED_ENV_NAMES`: optional comma or whitespace separated list of environment variable names that should be treated as explicitly risk-accepted by the environment probe.

Set a variable to `0` only for focused tests. Production use should keep the
defaults.

## Development

Run the self-test workflow in GitHub Actions. It verifies both successful and
intentionally unsafe Docker configurations.

Local syntax checks:

```bash
bash -n scripts/gha-sandbox-probe.sh
bash -n actions/docker-sandbox/run.sh
```

## License

MIT
