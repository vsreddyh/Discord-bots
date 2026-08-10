#!/usr/bin/env bash
set -euo pipefail

# Whole-host Linux usage sampler + reporter.
#
# `record` appends one line per run to run/sysmon/YYYY-MM-DD.tsv with
#   epoch  cpu%  load1  mem%  swap%  disk%
# (CPU% is measured as a 1s delta inside the call, so each cron run is
# self-contained — no state between runs.)
#
# `report [YYYY-MM-DD]` prints current / avg / min / max / p95 for each
# metric from that day's samples (default: today). Sends to Discord if
# DISCORD_BOT_TOKEN + DISCORD_HOME_CHANNEL are set (master bot channel).
#
# `install` / `remove` manage crontab entries: sample every minute, plus a
# 23:59 daily report that gets posted to Discord.

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TSV_DIR="$REPO/run/sysmon"

osample="${TSV_DIR}/$(date +%F).tsv"

# shellcheck source=scripts/lib/common.sh
. "$REPO/scripts/lib/common.sh"

# ── Sample one row ─────────────────────────────────────
sample() {
    local cpu load1 now mem_pct used_mem swap_pct disk_pct
    local pre_total pre_idle post_total post_idle dtotal didle

    load1="$(cut -d' ' -f1 /proc/loadavg)"

    # CPU% via two /proc/stat reads ~1s apart (tmp worktables keep /proc/stat
    # deltas local to this call, so each cron run is self-contained).
    read -r pre_total pre_idle < <(awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; print t, $5}' /proc/stat)
    sleep 1
    read -r post_total post_idle < <(awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; print t, $5}' /proc/stat)

    dtotal=$((post_total - pre_total)); didle=$((post_idle - pre_idle))
    if (( dtotal > 0 )); then
        cpu=$(( (dtotal - didle) * 100 / dtotal ))
    else
        cpu=0
    fi

    read -r total_mem free_mem < <(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{print t, a}' /proc/meminfo)
    if (( total_mem > 0 )); then
        mem_pct=$(( (total_mem - free_mem) * 100 / total_mem ))
        used_mem=$(( (total_mem - free_mem) / 1024 ))
    else
        mem_pct=0; used_mem=0
    fi

    read -r swap_total swap_free < <(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{print t, f}' /proc/meminfo)
    if (( swap_total > 0 )); then
        swap_pct=$(( (swap_total - swap_free) * 100 / swap_total ))
    else
        swap_pct=0
    fi

    disk_pct="$(df / --output=pcent 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)"

    now="$(date +%s)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$cpu" "$load1" "$mem_pct" "$swap_pct" "$disk_pct" >> "$osample"
}

# ── Stats for one day's file ───────────────────────────
stats() {
    local date="${1:-$(date +%F)}" f
    f="$TSV_DIR/$date.tsv"
    [[ -f "$f" ]] || { warn "no samples for $date ($f)"; exit 1; }

    local n
    n=$(wc -l < "$f")

    local body
    body="$(python3 - "$f" "$date" <<'PY'
import statistics, sys
f, date = sys.argv[1], sys.argv[2]
rows = []
for line in open(f):
    parts = line.rstrip("\n").split("\t")
    if len(parts) == 6:
        rows.append([float(p) for p in parts])
if not rows:
    print("no rows"); raise SystemExit(0)
cur = rows[-1]
lines = [f"sysmon · {date} · {len(rows)} samples", ""]
labels = ["cpu%", "load1", "mem%", "swap%", "disk%"]
hdr = f"{'':<8}{'cur':>8}{'avg':>8}{'min':>8}{'max':>8}{'p95':>8}"
lines.append(hdr)
lines.append("-" * len(hdr))
for i, label in enumerate(labels, start=1):
    col = [r[i] for r in rows]
    avg = statistics.fmean(col)
    p95 = sorted(col)[int(0.95 * (len(col) - 1))]
    lines.append(f"{label:<8}{cur[i]:>8.1f}{avg:>8.1f}{min(col):>8.1f}{max(col):>8.1f}{p95:>8.1f}")
print("\n".join(lines))
PY
)"
    echo "$body"
    if [[ "${POST_DISCORD:-0}" == "1" ]]; then
        post_discord "$body"
    fi
}

post_discord() {
    local token channel
    token="${DISCORD_BOT_TOKEN:-}"
    channel="${DISCORD_HOME_CHANNEL:-}"
    # Cron doesn't inherit .env — pull the master-bot values if unset.
    if [[ -z "$token" || -z "$channel" ]]; then
        token="$(grep -E '^DISCORD_BOT_TOKEN_MASTER=' "$REPO/.env" | tail -1 | cut -d= -f2-)"
        channel="$(grep -E '^DISCORD_HOME_CHANNEL_MASTER=' "$REPO/.env" | tail -1 | cut -d= -f2-)"
    fi
    if [[ -z "$token" || -z "$channel" ]]; then
        warn "DISCORD_BOT_TOKEN(_MASTER) / DISCORD_HOME_CHANNEL(_MASTER) not set — skipping Discord post."
        return 1
    fi
    curl -sf -o /dev/null -X POST \
        -H "Authorization: Bot $token" \
        -H "Content-Type: application/json" \
        -d "$(printf '{"content":%s}' "$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<<"$1")")" \
        "https://discord.com/api/v10/channels/$channel/messages" \
        || warn "Discord post failed."
    info "posted daily report to Discord."
}

# ── Cron management ────────────────────────────────────
cron_lines() {
    echo "* * * * * bash $REPO/scripts/sysmon.sh record >> $REPO/run/sysmon.log 2>&1"
    echo "59 23 * * * env POST_DISCORD=1 bash $REPO/scripts/sysmon.sh report >> $REPO/run/sysmon.log 2>&1"
}

install_cron() {
    command -v crontab >/dev/null 2>&1 || { warn "crontab not found"; return 1; }
    if crontab -l 2>/dev/null | grep -qF "sysmon.sh record"; then
        info "sysmon cron already installed."
        return 0
    fi
    ( crontab -l 2>/dev/null | grep -vF "sysmon.sh"; cron_lines ) | crontab -
    info "sysmon cron installed: sample every minute + daily 23:59 report."
}

remove_cron() {
    if command -v crontab >/dev/null 2>&1; then
        ( crontab -l 2>/dev/null | grep -vF "sysmon.sh" ) | crontab - || true
        info "sysmon cron removed."
    fi
}

# ── Entry ──────────────────────────────────────────────
cmd="${1:-report}"
case "$cmd" in
    record) mkdir -p "$TSV_DIR"; sample ;;
    report) export POST_DISCORD="${POST_DISCORD:-0}"; stats "${2:-$(date +%F)}" ;;
    install) install_cron ;;
    remove) remove_cron ;;
    *) warn "usage: $0 {record|report [YYYY-MM-DD]|install|remove}"; exit 1 ;;
esac