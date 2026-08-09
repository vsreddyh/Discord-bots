# VPS sizing — 5-bot Hermes stack (Dockerized)

Fully Dockerized stack: 5 Hermes bots + zen-proxy + searxng + health-api + dashboard + retention.
MongoDB stays **remote** (Atlas) — no Mongo container or storage counted below.

**Key fact: no LLM inference happens on this box.** OpenCode Zen / DeepInfra run the models, the
bots just stream text. Bots are I/O-bound (they wait on Discord + the network), so CPU and RAM
stay modest. No GPU needed.

Concurrency tiers = number of Hermes agents running at the same time.
Always **single user per agent** — each bot serves one user, so an agent run is one
bounded conversation (never multi-user sessions in one bot). The tiers above are pure
"how many bots are being used right now", and the max is 5 single-user sessions.

| Tier | RAM | CPU | Disk | Network |
|---|---|---|---|---|
| Minimum — 1 agent at a time | 4 GB | 2 vCPU | 30 GB | 100 Mbps |
| Recommended — 2 at the same time | 6 GB | 2 vCPU | 50 GB | 100 Mbps |
| Maximum — all 5 at the same time | 8 GB | 4 vCPU | 80 GB | 100 Mbps |

## OS

- **Ubuntu 24.04 LTS (x86_64)** — supported until 2029; clean Docker/systemd/Tailscale support. Debian 12 is the fallback.
- No host Hermes install anymore — the stack is 100% containers, so the OS stays minimal.

## RAM — why these numbers

Fixed base, all 10 services resident but idle: **~3.5 GB**

- 5 bots × ~350 MB idle ≈ 1.75 GB
- searxng ~0.3 GB, zen-proxy ~0.15 GB, health-api ~0.15 GB, dashboard ~0.15 GB
- Docker + OS ≈ 1.0 GB

Each **concurrently active agent** adds ~0.6 GB (conversation context + tool output; the model
itself runs elsewhere).

- Minimum (1 active): 3.5 + 0.6 + headroom = **4 GB**
- Recommended (2 active): 3.5 + 1.2 + headroom = **6 GB**
- Maximum (5 active): 3.5 + 3.0 + headroom = **8 GB**

Add ~2 GB swap as a spike buffer. These already match common provider tiers (4/6/8).

## CPU

- Agents are I/O-bound; 2 vCPU handles the minimum and recommended tiers comfortably.
- Searxng spawns a short-lived worker per search query — the only real CPU spike.
- 4 vCPU only for the all-5-at-once tier as breathing room. More is wasted.

## Disk — whole numbers

- Docker images are small: bot image 457 MB, searxng 258 MB, zen-proxy 187 MB, health-api 198 MB → ~1.5 GB total.
- Real consumers: container writable layers, Docker logs from chatty bots, profile state, backups.
- 30 GB is the floor; 50 GB leaves room for logs + snapshots; 80 GB for max comfort.
- Enable Docker log rotation (`max-size`) to keep the floor low.

## Network

- Discord WebSocket + REST and LLM text streaming are small; **latency matters, bandwidth barely does**.
- **100 Mbps is enough for every tier.** Only pay for more if the provider bundles it at no cost.
- Tailscale adds negligible overhead (WireGuard is CPU-light).

## Access

- Dashboard (:9119) + health-api (:8001) reachable **only over the Tailnet**.
- ufw: default-deny with `allow in on tailscale0` — never exposed to the public internet.
- SSH on 22 via the Tailnet (or your chosen source IPs).
