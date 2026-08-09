FROM python:3.11-alpine

ENV PYTHONUNBUFFERED=1

RUN apk add --no-cache bash git openssh-client curl sqlite

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
    src = re.sub(r'    "hermes-discord": \{\n.*?\n    \},\n', new_block, src, count=1, flags=re.S)
    src = src.replace('"hermes-telegram", "hermes-discord"', '"hermes-telegram", "hermes-god"')
    toolsets.write_text(src)

pf = platforms.read_text()
if "hermes-god" not in pf:
    platforms.write_text(pf.replace("hermes-discord", "hermes-god"))
PY

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
