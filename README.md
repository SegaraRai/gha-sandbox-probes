# GitHub Actions Sandbox Probes

`gha-sandbox-probes` provides small, auditable checks for GitHub Actions jobs that
run untrusted code inside a sandbox.

The project has two entry points:

- A composite GitHub Action that starts a hardened Docker sandbox, runs the
  probes, and then runs a command inside a sanitized environment.
- A standalone shell script that can be pinned by commit SHA and fetched from
  `raw.githubusercontent.com` or vendored as a submodule.

The probes are intended to fail closed. If a job exposes runner internals,
Actions runtime credentials, Docker control sockets, or unexpected process
visibility, the script exits non-zero.

## Threat Model

These probes are designed for CI jobs where the payload may execute arbitrary
code, such as compatibility tests against third-party dependency graphs.

The checks focus on detecting:

- GitHub Actions runtime, cache, results, and OIDC credentials in the sandbox.
- Docker daemon access through `/var/run/docker.sock`, `/run/docker.sock`, or
  `DOCKER_HOST`.
- Effective Linux capabilities inside the sandbox.
- Visibility of host GitHub Actions runner processes through `/proc`.
- Writable workspace mounts when a read-only workspace is expected.

The probes are not a complete sandbox. They are runtime assertions that help
verify that a separate sandboxing mechanism is actually in effect.

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

The action intentionally does not know how to install project dependencies. Run
project-specific setup in `command`, or call a setup script that you own and pin
by commit SHA.

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

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `image` | yes | | Docker image used for the sandbox. |
| `command` | yes | | Command to run after the probes pass. |
| `workspace` | no | `${{ github.workspace }}` | Host path mounted read-only at `/workspace`. |
| `user` | no | `1001` | Container user. |
| `pids-limit` | no | `512` | Docker process limit. |
| `network` | no | `bridge` | Docker network mode. Use `none` only when the command needs no network. |
| `env` | no | | Newline-separated `KEY=value` entries passed to the sandbox command. |
| `inherit-env` | no | | Newline, comma, or space separated variable names inherited from the caller environment. |
| `force-color` | no | `true` | Sets `TERM`, `COLORTERM`, `FORCE_COLOR`, and `CLICOLOR_FORCE` for tools that disable color in non-TTY CI output. |

The action refuses to pass known sensitive GitHub Actions variables such as
`ACTIONS_RUNTIME_TOKEN`, `ACTIONS_CACHE_URL`, `ACTIONS_RESULTS_URL`,
`ACTIONS_ID_TOKEN_REQUEST_TOKEN`, `GITHUB_TOKEN`, GitHub file-command paths such
as `GITHUB_ENV` and `GITHUB_OUTPUT`, and package publishing tokens.
`HOME` is always managed by the sandbox. `PATH` can be set explicitly with
`env`, but it cannot be inherited from the host environment.

## Project Setup

Keep setup separate from the sandbox runner. For example, a repository can own a
script such as `.github/scripts/setup-vite-plus.sh`:

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
- `GHA_SANDBOX_READONLY_PATHS`: defaults to `/workspace`.

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
