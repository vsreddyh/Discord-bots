# Discord Voice Channel

## Requirements

- `discord.voice_fx.enabled: true` in `config.yaml` (already set in `default-config.yaml`)
- `edge-tts` pip package (auto-installed by init)
- `PyNaCl>=1.5.0` + `davey` (auto-installed by init)
- System packages: `libopus0`, `ffmpeg` (auto-installed by init)

## Usage

The bot uses slash commands — no prefix needed.

### Join a voice channel

```
/voice join
```

The bot joins the voice channel you're currently in.

### Control reply mode

| Command | Behavior |
|---|---|
| `/voice tts` | Voice reply to **all** messages (text + voice) |
| `/voice on` | Voice reply only when you send a voice message |
| `/voice off` | Text only (default) |
| `/voice status` | Show current voice mode |

### Leave

```
/voice leave
```

## How it works

1. Bot joins voice channel (`/voice join`)
2. Bot listens for your messages in text chat or voice messages
3. Before running tools, bot says an acknowledgement phrase ("Let me look into that...")
4. While tools run, a subtle ambient "thinking" sound plays
5. Bot speaks the final response using Edge TTS

## Notes

- Ambient sounds duck (lower volume) when the bot speaks, then swell back
- Acks fire at most once per turn, only when in a voice channel
- Configure voice FX in `config.yaml` under `discord.voice_fx`:
  - `ambient_enabled` — idle thinking bed
  - `ack_enabled` — short phrases before tool calls
  - `ack_phrases` — customize the phrases
  - `ambient_gain` / `speech_gain` / `duck_gain` — volume levels
