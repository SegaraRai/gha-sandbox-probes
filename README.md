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
    image: mcr.microsoft.com/playwright:v1.60.0-noble
    workspace: .
    user: "1001"
    setup: vite-plus
    env: |
      CI=true
      LINGUI_WASM_PREBUILT=1
      TMPDIR=/tmp
    command: vp run test:compat --case "${{ matrix.case }}"
```

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
| `setup` | no | `none` | Optional setup. Currently supports `none` and `vite-plus`. |
| `env` | no | | Newline-separated `KEY=value` entries passed to the sandbox command. |

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
