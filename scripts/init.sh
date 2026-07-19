#!/usr/bin/env bash
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
BINDIR="$HOME/.local/bin"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ────────────────────────────────────────────────────────────
# Preset configuration via environment variables
# ────────────────────────────────────────────────────────────
#  Provider & Model
HERMES_PROVIDER="${HERMES_PROVIDER:-openrouter}"
HERMES_MODEL="${HERMES_MODEL:-deepseek/deepseek-chat-v3-0324:free}"
HERMES_API_KEY="${HERMES_API_KEY:-}"
HERMES_BASE_URL="${HERMES_BASE_URL:-}"

#  Terminal
HERMES_TERMINAL_BACKEND="${HERMES_TERMINAL_BACKEND:-local}"
HERMES_TERMINAL_TIMEOUT="${HERMES_TERMINAL_TIMEOUT:-180}"

#  Agent behaviour
HERMES_MAX_TURNS="${HERMES_MAX_TURNS:-90}"
HERMES_REASONING="${HERMES_REASONING:-medium}"
HERMES_MEMORY_ENABLED="${HERMES_MEMORY_ENABLED:-false}"

#  Comma-separated list of toolsets to disable (default: off by default)
HERMES_DISABLED_TOOLSETS="${HERMES_DISABLED_TOOLSETS:-browser,code_execution,computer_use,cronjob,delegation,discord,discord_admin,feishu_doc,feishu_drive,homeassistant,image_gen,kanban,memory,project,session_search,skills,spotify,tts,video,video_gen,vision,web,x_search,yuanbao}"

#  Extra API keys (semicolon-separated: KEY=val;KEY2=val2)
HERMES_EXTRA_KEYS="${HERMES_EXTRA_KEYS:-}"

# ────────────────────────────────────────────────────────────
# Step 1: Install Hermes
# ────────────────────────────────────────────────────────────
if command -v hermes &>/dev/null; then
    info "Hermes is already installed at $(command -v hermes)"
    hermes --version 2>&1 | head -1
else
    info "Hermes not found. Installing..."
    bash <(curl -fsSL https://hermes-agent.nousresearch.com/install.sh)
    if ! command -v hermes &>/dev/null; then
        error "Installation succeeded but 'hermes' not on PATH."
        echo "  Add to your shell rc: export PATH=\"$BINDIR:\$PATH\""
        exit 1
    fi
    info "Hermes installed successfully."
fi

# ────────────────────────────────────────────────────────────
# Step 2: Write config.yaml
# ────────────────────────────────────────────────────────────
mkdir -p "$HERMES_HOME"

# Convert comma-separated disabled toolsets to YAML list
DISABLED_LIST=""
if [[ -n "$HERMES_DISABLED_TOOLSETS" ]]; then
    IFS=',' read -ra TOOLS <<< "$HERMES_DISABLED_TOOLSETS"
    for t in "${TOOLS[@]}"; do
        t="$(echo "$t" | xargs)"  # trim
        if [[ -n "$t" ]]; then
            DISABLED_LIST="$DISABLED_LIST\n    - $t"
        fi
    done
fi

if [[ ! -f "$HERMES_HOME/config.yaml" ]]; then
    info "Writing preset config.yaml ..."

    BASE_URL_LINE=""
    if [[ -n "$HERMES_BASE_URL" ]]; then
        BASE_URL_LINE="  base_url: $HERMES_BASE_URL"
    fi

    cat > "$HERMES_HOME/config.yaml" <<CONFIGEOF
model:
  default: $HERMES_MODEL
  provider: $HERMES_PROVIDER
${BASE_URL_LINE}
agent:
  max_turns: $HERMES_MAX_TURNS
  reasoning_effort: $HERMES_REASONING
  disabled_toolsets:
    $(echo -e "$DISABLED_LIST" | sed '1d')
terminal:
  backend: $HERMES_TERMINAL_BACKEND
  cwd: .
  timeout: $HERMES_TERMINAL_TIMEOUT
compression:
  enabled: true
  threshold: 0.5
  target_ratio: 0.2
  protect_last_n: 20
  protect_first_n: 3
display:
  compact: false
  skin: default
  streaming: true
  show_reasoning: false
  tool_progress: all
memory:
  memory_enabled: $HERMES_MEMORY_ENABLED
  user_profile_enabled: false
  memory_char_limit: 2200
  user_char_limit: 1375
delegation:
  max_iterations: 50
skills:
  creation_nudge_interval: 15
security:
  redact_secrets: true
code_execution:
  timeout: 300
  max_tool_calls: 50
streaming:
  enabled: false
prompt_caching:
  cache_ttl: 5m
onboarding:
  seen:
    openclaw_residue_cleanup: true
    profile_build_offered: true
_config_version: 33
CONFIGEOF

    info "Config written to $HERMES_HOME/config.yaml"
else
    info "Config already exists at $HERMES_HOME/config.yaml — skipping."
fi

# ────────────────────────────────────────────────────────────
# Step 3: Write .env
# ────────────────────────────────────────────────────────────
ENV_FILE="$HERMES_HOME/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    info "Writing preset .env ..."

    # Map provider to expected env-var name
    PROVIDER_KEY_VAR=""
    case "$(echo "$HERMES_PROVIDER" | tr '[:upper:]' '[:lower:]')" in
        openrouter)   PROVIDER_KEY_VAR="OPENROUTER_API_KEY" ;;
        anthropic)    PROVIDER_KEY_VAR="ANTHROPIC_API_KEY" ;;
        openai)       PROVIDER_KEY_VAR="OPENAI_API_KEY" ;;
        google)       PROVIDER_KEY_VAR="GOOGLE_API_KEY" ;;
        deepseek)     PROVIDER_KEY_VAR="DEEPSEEK_API_KEY" ;;
        groq)         PROVIDER_KEY_VAR="GROQ_API_KEY" ;;
        xai)          PROVIDER_KEY_VAR="XAI_API_KEY" ;;
        nous)         PROVIDER_KEY_VAR="" ;;  # OAuth, no key needed
        *)            PROVIDER_KEY_VAR="" ;;
    esac

    {
        echo "# Hermes Agent Environment Configuration"
        echo "# Auto-generated by init.sh"
        echo ""
        if [[ -n "$PROVIDER_KEY_VAR" && -n "$HERMES_API_KEY" ]]; then
            echo "$PROVIDER_KEY_VAR=$HERMES_API_KEY"
            echo ""
        fi
        if [[ -n "$HERMES_EXTRA_KEYS" ]]; then
            echo "# Extra API keys"
            IFS=';' read -ra EXTRA <<< "$HERMES_EXTRA_KEYS"
            for pair in "${EXTRA[@]}"; do
                echo "$pair"
            done
            echo ""
        fi
        echo "TERMINAL_ENV=$HERMES_TERMINAL_BACKEND"
        echo "TERMINAL_TIMEOUT=$HERMES_TERMINAL_TIMEOUT"
    } > "$ENV_FILE"

    info "Env file written to $ENV_FILE"
else
    info ".env already exists at $ENV_FILE — skipping."
fi

# ────────────────────────────────────────────────────────────
# Step 4: Run doctor (diagnostics)
# ────────────────────────────────────────────────────────────
info "Running diagnostics..."
hermes doctor --fix 2>&1 || true

# ────────────────────────────────────────────────────────────
# Step 5: Pre-build dashboard UI
# ────────────────────────────────────────────────────────────
if [[ -d "$HERMES_HOME/hermes-agent/web" ]]; then
    if [[ ! -d "$HERMES_HOME/hermes-agent/web/dist" ]]; then
        info "Pre-building dashboard UI..."
        (cd "$HERMES_HOME/hermes-agent/web" && npm install --silent && npm run build --silent) || \
            warn "Dashboard UI build skipped (npm not available or build failed). Use --skip-build at runtime."
    fi
fi

echo
info "Hermes initialization complete."
echo ""
echo "  Provider  : $HERMES_PROVIDER"
echo "  Model     : $HERMES_MODEL"
echo "  Dashboard : http://127.0.0.1:9119"
echo "  Start     : ./scripts/start.sh"
echo "  Stop      : ./scripts/stop.sh"
echo "  Logs      : $HERMES_HOME/dashboard.log"
echo ""
echo "  To re-run with different presets, set env vars and run again:"
echo "    HERMES_PROVIDER=openrouter \\"
echo "    HERMES_MODEL=anthropic/claude-sonnet-4 \\"
echo "    HERMES_API_KEY=sk-... \\"
echo "    bash scripts/init.sh"
