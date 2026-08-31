# sandboxy

```
$ sandboxy run claude
  ┌──────────────┐
  │ ░░░░░░░░░░░░ │  Sandboxy
  │ ░░░░░░░░░░░░ │  Agent: Claude Code
  │ ░░░░░░░░░░░░ │  Instance: claude-20260328-150531
  │ ░░░░░░░░░░░░ │  Environment: 15 hours ago
  │ ░░░░░░░░░░░░ │  Workspace: /Volumes/code/vessel/containerization
  │ ░░░░░░░░░░░░ │  CPUs: 4  Memory: 4 GB
  └──────────────┘
  Command: claude --dangerously-skip-permissions
  Allowed hosts: *.anthropic.com, npm.org, *.npmjs.org, *.github.com, *.githubusercontent.com, *.pypi.org
  Mounts:
    /your/code -> /your/code
    /Users/you/.claude -> /root/.claude

Welcome to Claude Code v2.1.76
…………………………………………………………………………………………………………………………………………………………

     *                                       █████▓▓░
                                 *         ███▓░     ░░
            ░░░░░░                        ███▓░
    ░░░   ░░░░░░░░░░                      ███▓░
   ░░░░░░░░░░░░░░░░░░░    *                ██▓░░      ▓
                                             ░▓▓███▓▓░
 *                                 ░░░░
                                 ░░░░░░░░
                               ░░░░░░░░░░░░░░░░
       █████████                                        *
      ██▄█████▄██                        *
       █████████      *
…………………█ █   █ █………………………………………………………………………………………………………………

 Let's get started.
```

`sandboxy` runs AI coding agents in sandboxed Linux environments on macOS with Apple silicon.

One command to get an isolated agent session. Your current working directory is mounted in, your config carries over, and the environment is cached for fast subsequent runs.

> **Note:** This is an experimental tool. Behavior/flags/commands may change across releases. Its main goal was to be a good showcase of using the `Containerization` libraries API surface to build novel tools.

> **Note:** The tool does HTTPS/HTTP filtering today for network traffic originating from the container, but can currently reach services listening on `0.0.0.0` on the host. This should be tightened up in a future release whenever `Containerization` gains nftables support.

## Why?

AI coding agents work best when they can install packages, run builds, and execute code freely, but giving them unrestricted access to your host machine is risky. `sandboxy` aims to alleviate some worry by running agents inside lightweight Linux VMs on macOS. Your project directory is mounted in so the agent can read and write files, but everything else like network access, host filesystem view, and installed packages is isolated. No daemon, just a single command that gets out of your way.

## How?

`sandboxy` boots a Micro VM for every agent session using the [`Containerization`](https://github.com/apple/containerization) Swift package. Each agent session runs in its own VM.

### Caching

The first time you run an agent, `sandboxy` does a fair amount of setup: downloading a Linux kernel (unless you provide one), pulling the base OCI image, unpacking it into a root filesystem, and running the agent's install commands. All of this is cached so that subsequent runs skip straight to booting the VM. In practice, a warm start takes under a second.

The cache has a few layers:

- **Kernel** -- downloaded once and reused across all agents.
- **Init image** -- the minimal init process (`vminit`) that bootstraps the VM, pulled from an OCI registry and cached locally.
- **Agent rootfs** -- the fully-installed root filesystem for a given agent (e.g., `claude`). This is an ext4 disk image that includes the base image layers plus everything the agent's install commands produce.
- **Instance rootfs** -- every session saves its rootfs so it can be resumed later with `--name`. See [Instance Persistence](#instance-persistence).

On each run, the cached rootfs is cloned (via copy-on-write when the filesystem supports it) so the original cache stays clean. You can blow away any layer independently: `sandboxy cache rm <agent>` to rebuild a single agent, or `sandboxy cache clean --all` to start completely from scratch.

### Agent definitions

An agent is just a JSON file that describes how to set up and launch a particular tool. The built-in Claude Code definition specifies a base container image, a list of shell commands to install the toolchain, a launch command, and the environment variables needed at runtime. You can list available agents with `sandboxy config list --agents` and view any agent's definition with `sandboxy config list --agent <name>`.

You can override any built-in agent or define entirely new agents by dropping a JSON file in `~/.config/sandboxy/agents/`. Use `sandboxy config create --agent <name>` to scaffold a definition file (pre-filled with built-in defaults for known agents). Use `sandboxy config list --paths` to see all configuration file paths.

If the built-in install steps don't cover what you need, `sandboxy edit <agent>` drops you into an interactive shell inside the cached rootfs. Install extra packages, configure MCP servers, add language runtimes etc. Whatever you do is saved back to the cache and included in every future run.

### Workspace and mounts

Your host workspace directory is shared into the VM using virtio-fs, so reads and writes are reflected immediately on both sides. Additional host directories can be mounted with `--mount`, including read-only mounts for things like config or reference data that the agent shouldn't modify.

Agent definitions can include default mounts (e.g., `~/.claude` for Claude Code). To skip these on a specific run, pass `--no-agent-mounts`. CLI `--mount` flags are always applied regardless.

### Network isolation

By default, `sandboxy` enforces network isolation by placing the workload container on a host-only network with no internet route. A HTTP CONNECT proxy runs on the host and listens on the host-only network's gateway address. The workload's `HTTP_PROXY`/`HTTPS_PROXY` environment variables point at this proxy, which checks each request's target hostname against an allowlist and either tunnels it to the internet or returns a 403.

Additional hosts can be added at runtime with `--allow-hosts`. To disable filtering entirely, pass `--no-network-filter`.

## Quick Start

```bash
# Build
BUILD_CONFIGURATION=release make build

# Run Claude Code on the current directory
.build/release/sandboxy run claude
```

On first run, `sandboxy` downloads a kernel, pulls a base image, and installs the agent toolchain. This is cached automatically so subsequent runs generally start in less than a second.

## Supported Agents

- **Claude Code** - built-in

Additional agents can be added via JSON config files. See [Adding a New Agent](#adding-a-new-agent).

## Commands

### `sandboxy run <agent>`

Run an agent in a sandboxed container.

```bash
# Run on the current directory
sandboxy run claude

# Specify a workspace
sandboxy run --workspace ~/projects/myapp claude

# Allocate more resources
sandboxy run --cpus 8 --memory 8g claude

# Restrict network to specific hosts (in addition to agent defaults)
sandboxy run --allow-hosts api.example.com --allow-hosts internal.corp.com claude

# Disable network filtering entirely
sandboxy run --no-network-filter claude

# Mount additional directories (read-only or read-write)
sandboxy run --mount /tmp:/tmp:ro --mount ~/data:/data claude

# Skip mounts defined in the agent configuration
sandboxy run --no-agent-mounts claude

# Forward environment variables into the container
sandboxy run -e MY_TOKEN -e DEBUG=1 claude

# Forward the host SSH agent for git-over-SSH
sandboxy run --ssh-agent claude

# Give the instance a friendly name
sandboxy run --name my-feature claude

# Resume a named session
sandboxy run --name my-feature claude

# Ephemeral run (remove instance after session ends)
sandboxy run --rm claude

# Pass flags through to the agent
sandboxy run claude -- --model foobar
```

**Options:**

| Flag | Description | Default |
|------|-------------|---------|
| `-w`, `--workspace` | Host directory to mount | Current directory |
| `-m`, `--mount` | Additional mount (hostpath:containerpath[:ro\|rw], repeatable) | None |
| `-e`, `--env` | Set environment variable (KEY=VALUE or KEY to forward from host, repeatable) | None |
| `-k`, `--kernel` | Path to a Linux kernel | Auto-download |
| `--cpus` | Number of CPUs | 4 |
| `--memory` | Memory to allocate (e.g. `4g`, `512m`, `4096` for MB) | `4g` |
| `--allow-hosts` | Additional hostnames to allow (merged with agent defaults) | Agent defaults |
| `--no-network-filter` | Disable network filtering (allow unrestricted access) | Off |
| `--no-agent-mounts` | Skip mounts defined in the agent configuration | Off |
| `--name` | Persistent session name | Auto-generated |
| `--rm` | Remove instance after session ends | Off |
| `--reinstall` | Rebuild the cached environment from scratch | Off |
| `--ssh-agent` | Forward the host SSH agent socket into the container | Off |

### `sandboxy edit <agent>`

Open an interactive shell in the agent's cached environment. Install packages, configure MCP tools, add language runtimes etc.
Changes are saved back to the cache when you exit.

If no cache exists yet, the agent's install commands are run first. If any install step fails, you're dropped into the shell anyway so you can diagnose or finish the setup manually.

```bash
sandboxy edit claude

# Inside the container:
apt-get install -y python3-pip
pip3 install some-mcp-tool
exit  # changes are saved
```

Every future `sandboxy run claude` will include your changes.

### `sandboxy list` (alias: `ls`)

Show sandbox instances and their status.

```bash
sandboxy ls
```

### `sandboxy rm <name> [<name>...]`

Remove one or more instances and their preserved state.

```bash
# Remove a single instance
sandboxy rm my-feature

# Remove multiple instances
sandboxy rm instance-1 instance-2

# Remove all instances
sandboxy rm --all
sandboxy rm -a
```

### `sandboxy cache list`

Show cached environments and their disk usage.

### `sandboxy cache rm <agent>`

Remove a specific agent's cached environment. The next run will rebuild it.

### `sandboxy cache clean [--all] [--yes]`

Remove all cached environments and named instance state. If named instances exist, you'll be prompted for confirmation. With `--yes`, skip the prompt. With `--all`, also removes the kernel, init image, and content store, forcing a full re-download on the next run.

### `sandboxy config list`

Print current configuration or agent definitions.

```bash
# Print global defaults
sandboxy config list

# Print a specific agent's definition
sandboxy config list --agent claude

# List all available agents (built-in and custom)
sandboxy config list --agents

# Print configuration file paths
sandboxy config list --paths
```

### `sandboxy config create`

Create a default configuration or agent definition file. If the file already exists, you'll be prompted to confirm overwriting (use `--force` to skip).

For built-in agents (e.g. `claude`), the file is pre-filled with the built-in definition so you have a working starting point to customize.

```bash
# Create a global config.json with defaults
sandboxy config create

# Create an override for the built-in claude agent
sandboxy config create --agent claude

# Scaffold a new agent definition
sandboxy config create --agent myagent

# Overwrite an existing definition without prompting
sandboxy config create --agent claude --force
```

## Instance Persistence

Every session automatically saves its rootfs when it exits. The instance appears in `sandboxy ls` and can be resumed by passing its name to `--name`:

```bash
# First run -- auto-named instance
sandboxy run claude
# => Instance claude-20260328-091522 saved. Resume with: sandboxy run claude --name claude-20260328-091522

# Resume it
sandboxy run --name claude-20260328-091522 claude

# Or give it a memorable name upfront
sandboxy run --name my-feature claude

# List all instances
sandboxy ls

# Clean up
sandboxy rm my-feature

# Ephemeral run (nothing saved)
sandboxy run --rm claude
```

Use `--rm` for throwaway sessions that shouldn't persist.

## API Keys

Agent definitions can include environment variable names without values (e.g. `"ANTHROPIC_API_KEY"`), which are automatically forwarded from the host if set. The built-in Claude Code agent forwards `ANTHROPIC_API_KEY` this way. For custom agents, add the relevant key name to the `environmentVariables` array, or pass it at runtime with `-e`.

## Network Filtering

Network filtering is enabled by default. Each agent definition includes an `allowedHosts` list. Additional hosts can be added at runtime with `--allow-hosts`. An empty `allowedHosts` list means all traffic is denied. To disable filtering entirely, pass `--no-network-filter`.

The workload container runs on a **host-only network** with no internet route. A lightweight HTTP CONNECT proxy runs on the macOS host, bound to the host-only network's gateway address. The workload's proxy environment variables point at this address, so tools that respect `HTTP_PROXY`/`HTTPS_PROXY` route their traffic through the proxy automatically.

Note that the proxy relies on applications honoring `HTTP_PROXY`/`HTTPS_PROXY` environment variables. Tools that ignore these variables won't be able to reach the internet since the container has no direct internet route.

Agent toolchain installation (apt-get, npm install, etc.) runs with full network access on a shared network before the proxy is set up, so package repos don't need to be allowlisted.

## Adding a New Agent

Create a JSON file in the `agents/` directory, or use `sandboxy config create --agent <name>` to scaffold one:

`~/.config/sandboxy/agents/<name>.json`

Example (`foo.json`):

```json
{
    "displayName": "Foo",
    "baseImage": "docker.io/library/python:3.12-slim",
    "installCommands": [
        "pip install foo"
    ],
    "launchCommand": ["foo"],
    "environmentVariables": [],
    "mounts": [],
    "allowedHosts": ["api.example.com", "*.cdn.example.com"]
}
```

Then run it with `sandboxy run foo`.

To override a built-in agent, create a file with the same name (e.g., `claude.json`). Only the fields you include are overridden. Omitted fields keep their defaults. Use `sandboxy config list --agent claude` to see the full default definition.

## Configuration

Global defaults can be overridden with a config file:

`~/.config/sandboxy/config.json`

```json
{
    "dataDir": "/Volumes/fast/sandboxy",
    "kernel": "/path/to/vmlinux",
    "initfsReference": "ghcr.io/apple/containerization/vminit:0.26.5",
    "defaultCPUs": 8,
    "defaultMemory": "8g"
}
```

All fields are optional. Use `sandboxy config list` to see the defaults.

## Kernel

By default, `sandboxy` downloads a Linux kernel from the [Kata Containers](https://github.com/kata-containers/kata-containers) project (arm64 static release). The kernel is cached at `~/Library/Application Support/com.apple.containerization.sandboxy/kernel/vmlinux` and reused across all agent sessions.

To use your own kernel, pass it directly:

```bash
sandboxy run -k /path/to/vmlinux claude
```

Or set it permanently in `config.json`:

```json
{
    "kernel": "/path/to/vmlinux"
}
```

The kernel must be an uncompressed Linux kernel binary (`vmlinux`, not `bzImage` or `zImage`) built for arm64 with virtio drivers enabled (virtio-net, virtio-blk, virtio-fs, virtio-console at minimum).

## Building

```bash
make build
```

The built binary is at `.build/release/sandboxy`. It requires macOS 26 on Apple silicon.
