# GitHub Actions Sandbox Probes

`gha-sandbox-probes` runs untrusted or high-risk CI commands inside a hardened Docker sandbox, verifies that important GitHub Actions attack surfaces are not visible, and only then runs your command in a sanitized environment.

Use it for compatibility tests, dependency-graph tests, package-manager experiments, or other CI jobs where third-party code may execute.
It is designed for attacks that try to steal CI credentials, read runner process memory, poison caches, reach container runtimes, or exfiltrate cloud and package credentials.

There are two entry points:

- A composite GitHub Action that starts the Docker sandbox, runs the probes, and runs your command from a copied workspace.
- A standalone shell probe that can be pinned by commit SHA and executed inside a sandbox you create yourself.

The probes fail closed. If a required sandbox boundary is broken, the script exits non-zero.

## Quick Start

Pin the action to a full-length commit SHA.

> [!NOTE]
> This repository intentionally does not publish moving tags such as `v1` or release tags for the action.
> Consumers should pin the action to a full-length commit SHA so reviews can verify the exact code that will run in privileged workflow context.

```yaml
- uses: actions/checkout@v5
  with:
    persist-credentials: false

- name: Run compatibility in hardened sandbox
  uses: SegaraRai/gha-sandbox-probes@b18908cf314a4aa26e4cb705d21a1c272c4fb877
  with:
    image: ubuntu:24.04
    workspace: .
    command: |
      bash .github/scripts/run-compatibility.sh
```

The default network mode is `none`. If your sandboxed command must install dependencies or otherwise use outbound network, opt in explicitly:

```yaml
with:
  image: ubuntu:24.04
  network: bridge
  command: |
    bash .github/scripts/setup.sh
    bash .github/scripts/run-compatibility.sh
```

## Standalone Probe

Pin the raw URL to a full-length commit SHA and run the script inside the sandbox being evaluated.

```bash
curl -fsSL \
  https://raw.githubusercontent.com/SegaraRai/gha-sandbox-probes/b18908cf314a4aa26e4cb705d21a1c272c4fb877/scripts/gha-sandbox-probe.sh \
  -o gha-sandbox-probe.sh

docker run --rm \
  --user 1001 \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  --pids-limit 128 \
  --network none \
  --volume "$PWD:/workspace:ro" \
  --volume "$PWD/gha-sandbox-probe.sh:/probe.sh:ro" \
  ubuntu:24.04 \
  bash /probe.sh
```

Running the standalone script directly on a normal runner shell is expected to fail checks such as `container-marker` and `zero-capabilities`; it is meant to evaluate a sandbox, not to make the host runner safe by itself.

## Action Inputs

| Input                | Required | Default                   | Description                                                                                                                                                                                       |
| -------------------- | -------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `image`              | yes      |                           | Docker image used for the sandbox.                                                                                                                                                                |
| `command`            | yes      |                           | Command to run after the probes pass.                                                                                                                                                             |
| `workspace`          | no       | `${{ github.workspace }}` | Host path mounted read-only at `/workspace`.                                                                                                                                                      |
| `user`               | no       | `1001`                    | Container user.                                                                                                                                                                                   |
| `pids-limit`         | no       | `512`                     | Docker process limit.                                                                                                                                                                             |
| `network`            | no       | `none`                    | Docker network mode. Use `bridge` only when the sandboxed command needs outbound network.                                                                                                         |
| `env`                | no       |                           | Newline-separated `KEY=value` entries passed to the sandbox command.                                                                                                                              |
| `unsafe-env`         | no       |                           | Newline-separated `KEY=value` entries for sensitive CI environment variables intentionally exposed to the sandbox command.                                                                        |
| `inherit-env`        | no       | `auto`                    | Newline, comma, or space separated variable names inherited from the caller environment. Include `auto` to use the curated non-sensitive default set, or `none` to disable automatic inheritance. |
| `unsafe-inherit-env` | no       |                           | Newline, comma, or space separated sensitive CI environment variable names intentionally inherited into the sandbox command.                                                                      |
| `disable-checks`     | no       |                           | Comma, space, or newline separated probe checks to disable after explicit risk acceptance.                                                                                                        |

## Environment Passing

By default, the action inherits only a small allowlist of non-sensitive variables that preserve terminal behavior, locale, timezone, and reproducible build settings:

- Color and terminal: `TERM`, `COLORTERM`, `NO_COLOR`, `FORCE_COLOR`, `CLICOLOR`, `CLICOLOR_FORCE`
- Tool color controls: `CARGO_TERM_COLOR`, `CMAKE_COLOR_DIAGNOSTICS`, `PY_COLORS`, `PYTHON_COLORS`
- Locale and timezone: `LANG`, `LANGUAGE`, `LC_*`, `TZ`
- Reproducibility: `SOURCE_DATE_EPOCH`

Package registry, proxy, cloud, and private module environment variables are not inherited by default because they often contain credentials or private package names.
Pass non-sensitive values with `env`, or inherit specific names with `inherit-env`, when you understand the exposure.

GitHub Actions runtime, cache, OIDC, file-command, package-token, SSH-agent, and similar CI credential variables are blocked from normal `env` and `inherit-env`.
To expose one anyway, use `unsafe-env` or `unsafe-inherit-env`; these inputs are intentionally verbose because the sandboxed command can read and exfiltrate those values.

Explicitly passed or inherited variable names are registered in `GHA_SANDBOX_ALLOWED_ENV_NAMES` before the probe runs.
The probe excludes those names from environment-name and URL-userinfo checks, but still checks structural sandbox boundaries such as runner process visibility, container runtime sockets, credential files, metadata token endpoints, capabilities, and writable mounts.

`HOME` is always managed by the sandbox. `PATH` can be set explicitly with
`env`, but it cannot be inherited from the host environment.

## Runtime Behavior

The sandbox image must provide `bash`, `awk`, `env`, `grep`, `head`, `mkdir`, `tar`, and `tr`.
The action overrides the image entrypoint with `bash`, so the image entrypoint cannot run before the probes.
Minimal images such as distroless images, Alpine without Bash, or slim images missing these utilities will fail before the sandboxed command runs.

The host workspace is mounted read-only at `/workspace`, then copied to `/tmp/workspace` without `.git`. The sandboxed command runs from `/tmp/workspace`; changes made there do not persist to later workflow steps.
This avoids exposing checkout credentials that may exist in Git metadata, but large repositories pay the cost of copying the workspace.

The action intentionally does not know how to install project dependencies.
Keep setup separate from the sandbox runner. For example:

```yaml
with:
  network: bridge
  command: |
    bash .github/scripts/setup.sh
    bash .github/scripts/run-compatibility.sh
```

## Threat Model

The probes are designed for CI jobs where the payload may execute arbitrary code, including package install hooks, dependency tests, third-party actions, or tools pulled from public ecosystems.

They are intended to catch or prevent exposure of:

- GitHub Actions runtime, cache, results, and OIDC credentials.
- Container runtime access through Docker, containerd, Podman, CRI-O, BuildKit, or `DOCKER_HOST`.
- Visibility of host GitHub Actions runner processes through `/proc`, including readable runner environment or memory files.
- Effective Linux capabilities inside the sandbox.
- Credential-bearing files commonly targeted by supply-chain malware, including Kubernetes service account tokens, cloud credentials, registry credentials, package-manager credentials, GitHub CLI hosts, Vault tokens, and SSH keys.
- Reachable AWS, Azure, and Google Cloud metadata credential endpoints.
- Environment variables that expose sensitive names or URL userinfo credentials.
- Writable workspace mounts when a read-only workspace is expected.

## Limits And User Responsibilities

This project is not a complete sandbox.
It is a set of runtime assertions that help verify that a separate sandboxing mechanism is actually in effect.

You are still responsible for:

- Pinning this action, the sandbox image, setup scripts, and third-party actions to immutable references where practical.
- Using `actions/checkout` with `persist-credentials: false` unless the job needs authenticated Git operations.
- Keeping secrets, write tokens, OIDC permissions, publish credentials, and trusted caches out of jobs that run untrusted code.
- Opting into `network: bridge` only when the sandboxed command needs outbound network.
- Treating anything passed through `unsafe-env`, `unsafe-inherit-env`, or `disable-checks` as an explicit risk acceptance.
- Reviewing package-manager install behavior. This action can isolate install scripts, but it does not decide which dependencies are trustworthy.

## Security Details

The default policy is secure by default. Checks that validate the core sandbox boundary are always on:

- `container-runtime-sockets`: Docker, containerd, Podman, CRI-O, BuildKit, and `DOCKER_HOST` must not expose host container control.
- `runner-processes`: if `/proc` is mounted, host GitHub Actions runner processes, their environment files, and their memory files must not be visible. A missing or restricted `/proc` is treated as non-observable rather than unsafe.

The following checks may be disabled only when the workflow owner explicitly accepts the risk:

| Check                      | Why it matters                                                                                                                                                                                        | Disable token                                                                        |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Container marker           | Confirms the command is running in a container-like boundary. Disable only for standalone probe tests outside containers.                                                                             | `container-marker`                                                                   |
| Zero Linux capabilities    | Capabilities increase the impact of sandbox escape attempts and kernel-facing attacks. Requires readable `/proc/self/status`; if `/proc` is unavailable, this check fails unless disabled.            | `zero-capabilities`                                                                  |
| Environment secrets        | Detects Actions runtime/cache/OIDC/file-command variables, token-like names, and URL userinfo credentials. Prefer `env`/`inherit-env` or `GHA_SANDBOX_ALLOWED_ENV_NAMES` for specific accepted names. | `environment`                                                                        |
| Credential files           | Detects common cloud, Kubernetes, registry, package-manager, GitHub CLI, Vault, and SSH credential files.                                                                                             | `credential-files`                                                                   |
| Cloud metadata credentials | Detects reachable AWS, Azure, and Google Cloud metadata token endpoints. Use provider-specific tokens when possible.                                                                                  | `cloud-metadata`, `cloud-metadata-aws`, `cloud-metadata-azure`, `cloud-metadata-gcp` |
| Read-only paths            | Verifies paths such as `/workspace` are not writable.                                                                                                                                                 | `readonly-paths`                                                                     |

You can disable accepted-risk checks from the action:

```yaml
with:
  disable-checks: |
    cloud-metadata-aws
    credential-files
```

For standalone script use:

```bash
GHA_SANDBOX_DISABLE_CHECKS="cloud-metadata-aws credential-files" \
  bash ./scripts/gha-sandbox-probe.sh
```

`all-risk-accepted` disables every accepted-risk check, but it does not disable the always-on sandbox boundary checks.

## Normal Runner Hardening

A normal GitHub Actions job without an inner sandbox is not equivalent to this isolation model.
Once untrusted code runs in a job, it can generally share that job's filesystem, network, process view, environment, checked-out files, caches, and available credentials.
GitHub-hosted runners reduce cross-job persistence by providing fresh job environments, but they do not isolate steps within the same job.

For jobs that cannot use this sandbox, reduce blast radius instead:

- Keep untrusted code out of `pull_request_target` and `workflow_run` jobs with secrets, write tokens, OIDC, or privileged cache access.
- Use top-level `permissions: {}` or least-privilege per-job permissions.
- Use `actions/checkout` with `persist-credentials: false` unless the job needs authenticated Git operations.
- Grant `id-token: write` only in the exact publish/deploy job that needs OIDC, and constrain cloud or registry trust policies by repository, ref, workflow, environment, and audience.
- Do not restore caches written by untrusted jobs into privileged publish or deploy jobs. Treat cache contents as untrusted inputs.
- Prefer deny-by-default egress controls and block cloud metadata endpoints, especially on self-hosted or cloud-hosted runners.

These controls are useful, but they reduce exposure rather than proving that arbitrary code cannot reach runner memory, job credentials, or shared job state.

## Standalone Script Environment

The script supports these optional environment variables:

- `GHA_SANDBOX_DISABLE_CHECKS`: comma or whitespace separated accepted-risk checks to disable. Supports `all-risk-accepted`.
- `GHA_SANDBOX_REQUIRE_CONTAINER`: defaults to `1`.
- `GHA_SANDBOX_REQUIRE_ZERO_CAPS`: defaults to `1`.
- `GHA_SANDBOX_CHECK_METADATA`: defaults to `1`.
- `GHA_SANDBOX_READONLY_PATHS`: defaults to `/workspace`.
- `GHA_SANDBOX_ALLOWED_ENV_NAMES`: optional comma or whitespace separated list of environment variable names that should be treated as explicitly risk-accepted by the environment probe.

Set a variable to `0` only for focused tests. Production use should keep the defaults.

## Development

Run the self-test workflow in GitHub Actions. It verifies both successful and intentionally unsafe Docker configurations.

Local syntax checks:

```bash
bash -n scripts/gha-sandbox-probe.sh
bash -n actions/docker-sandbox/run.sh
```

## License

MIT
