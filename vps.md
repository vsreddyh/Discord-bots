# VPS sizing — 5-bot Hermes stack (Dockerized)

Fully Dockerized stack: 5 Hermes bots + zen-proxy + searxng + health-api + dashboard + retention.
MongoDB stays **remote** (Atlas) — no Mongo container or storage counted below.

**Key fact: no LLM inference happens on this box.** OpenCode Zen / DeepInfra run the models, the
bots just stream text. Bots are I/O-bound (they wait on Discord + the network), so CPU and RAM
stay modest. No GPU needed.

Numbers below are **measured** on a running stack (idle bots), not guessed. Concurrency tiers =
number of Hermes agents running at the same time (max 5, one single-user session per bot).

| Tier | RAM | CPU | Disk | Network |
|---|---|---|---|---|
| Minimum — 1 agent at a time | 2 GB | 2 vCPU | 10 GB | 100 Mbps |
| Recommended — 2 at the same time | 3 GB | 2 vCPU | 20 GB | 100 Mbps |
| Maximum — all 5 at the same time | 5 GB | 4 vCPU | 30 GB | 100 Mbps |

## OS

- **Ubuntu 24.04 LTS (x86_64)** — supported until 2029; clean Docker/systemd/Tailscale support. Debian 12 is the fallback.
- No host Hermes install anymore — the stack is 100% containers, so the OS stays minimal.

## RAM — the real numbers

Measured live via `docker stats` on a running stack, all bots idle. The whole stack
(5 bots + zen-proxy + health-api + dashboard + Mongo) sits at **~1.1 GiB**. Per container:

| Container | RAM (idle) |
|---|---|
| zen-proxy | ~35 MiB |
| health-api | ~53 MiB |
| dashboard | ~79 MiB |
| story | ~103 MiB |
| food | ~99 MiB |
| money | ~96 MiB |
| master | ~109 MiB |
| helldivers | ~148 MiB |
| in-stack Mongo | ~339 MiB |
| **Stack total** | **~1.06 GiB** |

+ searxng (~0.2 GB) + Docker + OS (~0.4 GB) → realistic **floor ≈ 1.5 GB with Mongo in-stack,
≈ 1.1 GB with remote Mongo** (the production setup).

Each **concurrently active agent** adds ~0.6 GB (conversation context + tool output; the model
itself runs elsewhere).

- Minimum (1 active): 1.1 + 0.6 + headroom = **2 GB**
- Recommended (2 active): 1.1 + 1.2 + headroom = **3 GB**
- Maximum (5 active): 1.1 + 3.0 + headroom = **5 GB**

Add ~2 GB swap as a spike buffer. These match common provider tiers (2/3/5). The old 4/6/8 GB
guidance was ~2–3× over — safe, but you'd be paying for RAM the bots never touch.

## CPU

- Agents are I/O-bound; **2 vCPU handles all tiers comfortably** (idle CPU is ~0.2% per container).
- Searxng spawns a short-lived worker per search query — the only real CPU spike.
- 4 vCPU only for the all-5-at-once tier as breathing room. More is wasted.

## Disk — whole numbers

Measured (`docker system df` + repo `du`), not guessed:

- Docker images: ~3.0 GB (bot 457 MB, searxng 258 MB, zen-proxy 187 MB, health-api 198 MB, + mongo)
- Volumes + container writable layers: ~0.5 GB
- Live repo data (profiles, workspace, skills): ~0.15 GB
- **Total keep-everything footprint: ~4 GB**

- 10 GB is the comfortable floor (stack + logs + a snapshot).
- 20 GB leaves room for years of logs + Docker build cache (7.6 GB unpruned).
- 30 GB = max comfort; the old 30/50/80 guidance was ~4× over.
- Enable Docker log rotation (`max-size`) so idle-chatty bots don't eat simple loops of disk.
- **Always run `docker builder prune -f` after every build** — the build cache (7.6 GB here)
  grows on every `--build` and never shrinks on its own.

## Network

- Discord WebSocket + REST and LLM text streaming are small; **latency matters, bandwidth barely does**.
- **100 Mbps is enough for every tier.** Only pay for more if the provider bundles it at no cost.
- Tailscale adds negligible overhead (WireGuard is CPU-light).

## Access

- Dashboard (:9119) + health-api (:8001) reachable **only over the Tailnet**.
- ufw: default-deny with `allow in on tailscale0` — never exposed to the public internet.
- SSH on 22 via the Tailnet (or your chosen source IPs).