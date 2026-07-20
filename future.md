# Future: Multi-Profile Isolation

## Goal
Isolate Discord profile from CLI profile — each in its own folder, each with its own gateway, but sharing the same Hermes tools.

## Current Setup
- Single default profile
- Hermes runs on host (systemd)
- Discord and CLI share same filesystem (no folder restrictions)
- `default-config.yaml` sets `platform_toolsets` and `group_sessions_per_user`

## Plan

### 1. Create Discord profile
```bash
hermes profile create discord --clone default
```

Creates `~/.hermes/profiles/discord/config.yaml` + data folder.

### 2. Discord profile config overrides
- `terminal.backend: docker`
- `terminal.docker_volumes: ["~/discord-workspace:/workspace"]`
- `terminal.docker_mount_cwd_to_workspace: true`
- `terminal.cwd: /workspace`
- `group_sessions_per_user: false`
- `platform_toolsets.discord: [hermes-god]`

### 3. Discord gateway
```bash
hermes gateway start --profile discord
```

Starts a separate gateway process for Discord with the Discord profile's config.

### 4. Update `scripts/hermes.sh`
Add `--profile discord` flag to gateway commands for Discord operations.

### 5. Update `default-config.yaml`
Add per-profile config sections or create a separate `profile-discord.yaml` template.

## Key Details

- **Profiles vs containers**: Hermes profiles share the same Hermes installation but can override `terminal.backend`. Setting it to `docker` with different volume mounts per profile isolates file/terminal access.
- **File tools respect terminal backend**: When `terminal.backend: docker`, `read_file`, `write_file`, `patch`, `search_files` all route through `docker exec` into the container.
- **Independent gateways**: Each profile runs `hermes gateway start --profile <name>` as its own systemd service.
- **`hermes-god` toolset**: Custom toolset composed of `hermes-cli` + `debugging` + `coding` + `discord` + `discord_admin` (51 tools total). Defined in `toolsets.py`.

## hermes-god Toolset Definition

To create the custom `hermes-god` toolset, add this entry to `TOOLSETS` dict in `toolsets.py` (replace the existing `hermes-discord` entry):

```python
"hermes-god": {
    "description": "GOD Discord bot toolset - CLI + debugging + coding + Discord",
    "tools": [
        "discord",
        "discord_admin",
    ],
    "includes": ["hermes-cli", "debugging", "coding"]
},
```

Then update the default toolset for the Discord platform in `hermes_cli/platforms.py`:

```python
("discord", PlatformInfo(label="💬 Discord", default_toolset="hermes-god")),
```

And update the `hermes-gateway` includes list in `toolsets.py`:
```python
"includes": ["hermes-telegram", "hermes-god", ...]
```

Finally, reference `hermes-god` in the profile's `platform_toolsets.discord` in `config.yaml`:
```yaml
platform_toolsets:
  discord:
    - hermes-god
```
