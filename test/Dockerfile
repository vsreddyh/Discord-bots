FROM python:3.11-alpine

ENV PYTHONUNBUFFERED=1

RUN apk add --no-cache bash git openssh-client curl sqlite tectonic

RUN pip install --no-cache-dir hermes-agent 'discord.py[voice]==2.7.1' pymongo

RUN python - <<'PY'
import pathlib, re

sp = pathlib.Path("/usr/local/lib/python3.11/site-packages")
toolsets = sp / "toolsets.py"
platforms = sp / "hermes_cli" / "platforms.py"

src = toolsets.read_text()
if "hermes-god" not in src:
    new_block = (
        '    "hermes-god": {\n'
        '        "description": "GOD Discord bot toolset - CLI + debugging + coding + Discord",\n'
        '        "tools": [\n'
        '            "discord",\n'
        '            "discord_admin",\n'
        '        ],\n'
        '        "includes": ["hermes-cli", "debugging", "coding"]\n'
        '    },\n'
    )
    src, n = re.subn(r'    "hermes-discord": \{\n.*?\n    \},\n', new_block, src, count=1, flags=re.S)
    if n != 1:
        raise SystemExit("PATCH FAILED: hermes-discord block not found in toolsets.py — hermes-agent layout changed")
    src2 = src.replace('"hermes-telegram", "hermes-discord"', '"hermes-telegram", "hermes-god"')
    if src2 == src:
        raise SystemExit("PATCH FAILED: hermes-discord reference not found in toolsets.py — layout changed")
    src = src2
    toolsets.write_text(src)

pf = platforms.read_text()
if "hermes-god" not in pf:
    pf2 = pf.replace("hermes-discord", "hermes-god")
    if pf2 == pf:
        raise SystemExit("PATCH FAILED: 'hermes-discord' not found in platforms.py — layout changed")
    platforms.write_text(pf2)
PY

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
