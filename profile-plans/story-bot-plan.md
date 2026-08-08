# Story Bot

Hermes Agent profile: maintains the Mana Revolution lore vault
(`git@github.com:vsreddyh/portals.git`) via Discord. You describe story
events/characters/worldbuilding in chat; the bot updates every lore file the
fact touches, keeps the canon consistent, and commits+pushes to GitHub.

## Repo

- The bot clones the repo itself into its isolated workspace at setup:
  `git clone git@github.com:vsreddyh/portals.git` (private, SSH). Pull before
  each session so it stays in sync with the Obsidian vault and any other
  writer, and push after committing.
- Structure:
  - `Characters/` — `4 Gifts/`, `Family/`, `Supporting/` (one .md per character)
  - `World/` — `Places/`, `Organizations/`, `Species/`
  - `Magic System/` — `Portas/`, `Applications/`, `Paradaxos/`,
    `Ranking system/` (+ `Slope.md`, `Prompt.md`), `Techniques/`, root files
    (`Mana.md`, `Demons.md`, `Sorcerers.md`, `Sun Wukong's Staff.md`,
    `Mana Communication.md`)
  - `Misc/` — `Timeline.md`, `Jagad Vyah.md`
- `.gitignore` (in the clone): `.obsidian/`, `.trash/`, `.hermes/` (Obsidian/
  locals not committed).

## Scope

- **Input**: user describes story events, new characters, faction/place/species
  changes, power-system rules, deaths, timeline updates — free-form chat.
- **Output**: update **every file that fact touches** — append/replace the
  relevant bullet in `Misc/Timeline.md` saga/arc, add or update the character
  page, adjust faction/place/species pages, cross-link related notes, fix
  contradictions the new fact creates, re-check the whole vault for broken
  links after the edit.
- Consistency rules (inherited from `.hermes/project.md`):
  - The repo is the single source of truth; search it before answering.
  - Maintain internal consistency across all notes; point out contradictions or
    continuity errors.
  - Never invent facts unless the user explicitly asks for lore expansion.
  - Preserve established tone and canon.
  - Say so when information is missing instead of assuming.
- Git workflow:
  - `git status` before edits; show a summary of planned changes first.
  - Show `git diff` after editing.
  - Commit with clear messages, e.g. `feat(lore): ...`, `docs(characters): ...`,
    `fix(timeline): ...`.
  - **Push to `origin` (GitHub `portals`) after each update** — the user wants
    the remote maintained automatically.

## Vault update rules

- `Timeline.md` is for **major events only**. Map the described event to the
  right saga/arc (`Prelude Saga`, `Mana Release Saga`, `Portas Chaos Saga`,
  `Final Saga`) and its section, append the bullet in order, and use existing
  `[[wikilink]]` conventions (e.g. `[[Vayugrath|the hero]]`,
  `[[Clara|the heroine]]`). Minor details/backstory go in the character/world
  pages, not the timeline.
- Character pages: one file per character. New character → new file in the
  right subfolder (`Supporting/`, `Family/`, `4 Gifts/`). Existing character →
  update in place.
- Page naming matters — Obsidian links break on rename. If a page needs
  renaming, update all inbound `[[links]]` across the vault and commit that as
  a separate `refactor(links):` commit.
- Cross-links: after any update, check related pages (`World/Organizations/`,
  `Magic System/`, other characters) and add/verify `[[links]]` so the graph
  stays connected.
- Magic system is strict canon: `Slope.md` defines the rank→energy formula
  (Y = 1000 × 4^x), `Prompt.md` defines feat rules, `Portas.md` the portal
  rules. New power-system claims must be checked against these before writing.

## Chat Interaction

Free-form natural language; the bot decides what changed and where:

```
[I] Vargr's Paradaxos lets him see enemy weak points — it activates on direct eye contact with a living thing.
[B] Adds to Vargr.md, links Menagerie/System Paradaxos pages, flags that Timeline Arc 1 needs the 'needing his detection abilities' line cross-checked.

[I] Add a supporting character: a Dominion courier who defects to the Veilists in Arc 4.
[B] Creates Characters/Supporting/<name>.md, updates Dominionist/Veilist organization pages, adds Arc 4 timeline bullet.

[I] The Azure Dragon egg hatched early in Arc 2.
[B] Corrects Timeline Pre-Story bullet + Arc 2, updates 4 Gifts/Azure Dragon.md.
```

The bot replies with a plan (files to touch, diff after), then commits + pushes.

## Profile

Isolated workspace (same setup as food/money/helldivers bots), Discord-connected.
At setup the profile clones `git@github.com:vsreddyh/portals.git` (SSH key for
the account must be available to the profile). No cron — updates happen only
when the user asks. SQLite not required; the clone's git history + markdown
files are the store. The old `.hermes/project.md` in the repo was removed — it
referenced a dead path and the standalone profile replaces it.

### Discord identity

- Bot name: **Portas-Maintainer**
- Home channel: `1523762320986214541` (via `DISCORD_HOME_CHANNEL` /
  `channel_skill_bindings`)
- Token: per-profile `.env`, git-ignored — never commit it.
