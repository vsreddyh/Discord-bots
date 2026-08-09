# VPS sizing — 5-bot Hermes stack (Dockerized)

Fully Dockerized stack: 5 Hermes bots + zen-proxy + searxng + health-api + dashboard + retention.
MongoDB stays **remote** (Atlas) — no Mongo container or storage counted below.

Concurrency tiers = number of Hermes agents running at the same time.

| Tier | RAM | CPU | Disk | Network |
|---|---|---|---|---|
| Minimum — 1 agent at a time | 4.8 GB | 2 vCPU | 40 GB | 100 Mbps |
| Recommended — 2 at the same time | 6.4 GB | 4 vCPU | 80 GB | 500 Mbps |
| Maximum — all 5 at the same time | 12.8 GB | 8 vCPU | 120 GB | 1 Gbps |

## OS

- **Ubuntu 24.04 LTS (x86_64)** — supported until 2029; clean Docker/systemd/Tailscale support. Debian 12 is the fallback.
- No host Hermes install anymore — the stack is 100% containers, so the OS stays minimal.

## RAM — why these numbers

Fixed base, all 10 services resident but idle: **~3.5 GB**

- 5 bots × ~350 MB idle ≈ 1.75 GB
- searxng ~0.3 GB, zen-proxy ~0.15 GB, health-api ~0.15 GB, dashboard ~0.15 GB
- Docker + OS ≈ 1.0 GB

Each **concurrently active agent** adds ~1 GB on top (LLM streaming, conversation context, tool output).

- Minimum (1 active): 3.5 + 1.0 + 0.3 headroom = **4.8 GB**
- Recommended (2 active): 3.5 + 2.0 + 0.7 headroom = **6.4 GB**
- Maximum (5 active): 3.5 + 5.0 + 2.5 headroom = **12.8 GB**

Add ~2 GB swap in every tier as a spike buffer. If the provider only sells whole GB, round up (5 / 7 / 13).

## Disk — whole numbers

- Docker images are small: bot image 457 MB, searxng 258 MB, zen-proxy 187 MB, health-api 198 MB → ~1.5 GB total.
- Real consumers: container writable layers, Docker logs from 5 chatty bots, profile state, backups.
- Minimum 40 GB is the floor; recommended 80 GB leaves room for logs + snapshots; 120 GB for max comfort.
- Enable Docker log rotation (`max-size`) if you stay on the minimum tier.

## Network

- Discord WebSocket + REST and LLM streaming are all light — **latency to Discord/LLM providers matters more than raw bandwidth**.
- Tailscale adds negligible overhead (WireGuard is CPU-light).
- 100 Mbps works for the minimum tier; 500 Mbps–1 Gbps removes all doubt for heavy multi-agent use.

## Access

- Dashboard (:9119) + health-api (:8001) reachable **only over the Tailnet**.
- ufw: default-deny with `allow in on tailscale0` — never exposed to the public internet.
- SSH on 22 via the Tailnet (or your chosen source IPs).
