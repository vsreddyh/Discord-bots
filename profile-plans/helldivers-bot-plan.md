# Helldivers Bot

Hermes Agent profile: Helldivers 2 loadout, enemy, and planet knowledge via
Discord.

## Scope

- Q&A on weapons (primary/secondary), stratagems, warbonds, planets + their
  environmental conditions, loadout compatibility, enemy effectiveness + weak
  points (all three factions: Terminids, Automatons, Illuminate), missions,
  difficulties, economy/progression costs
- No scheduled updates — answers only when asked
- No loadout builder — answers questions with reasoning
- No live war state (current owners, liberation %, DSS) — data comes from the
  wiki only

## Data Sources

Single source: wiki scrape (`https://helldivers.wiki.gg/api.php`, MediaWiki
API).

The wiki encodes game data in **structured templates** — parse those, don't
hand-curate. Verified per template from live pages:

- `{{Infobox Planet}}` → sector, biome, environmental conditions (static
  hazards like Ion Storms, Fire Tornadoes), index
- `{{Infobox Enemy}}` → faction, size, class, health, damage, damage_type,
  min_difficulty, fire_mult, stagger_req, rank
- `{{Anatomy Row}}` → per-body-part health, **armor value (av)**, durability,
  percent_to_main, dmg_cap, bleed, fatal, exdr — this IS the penetration-zone
  data: which parts are armored (and what AP tier opens them) vs unarmored
  soft spots (Charger butt av 0, leg flesh av 2, head/torso av 4)
- `{{Infobox Weapon}}` → slot, category, type, damage, penetration AP,
  capacity, recoil, fire_rate, dps, spare_mags, traits, firing_modes,
  scope_options, source
- `Module:Weapon Attach/data_weapons.json` → per-weapon attachments: name,
  unlock level, cost; effects read by `Module:Weapon Attach` (ergonomics,
  zoom, sway, recoil, spread, mag capacity) when present in the JSON
- `{{Infobox Stratagem}}` + `{{Stratagem Stats Table}}` → permit_type,
  unlock_level, unlock_cost, traits, stratagem_code, call_time, uses,
  cooldown, rearm_time (base + upgraded)
- `{{Infobox Warbond}}` + `{{Acquisitions Page}}` → SC cost, release date,
  credit-claim, per-item medal cost, page, type (weapon/armor/booster/cosmetic)
- `{{Infobox Mission}}` → faction, time_limit, min/max difficulty, objective
  steps, per-difficulty kill requirements
- `{{Infobox Armor}}` → type (light/medium/heavy), armor value, speed, stamina
  regen, passive, cost
- `{{Enemy Loadout Box}}` → per-enemy attack: name, damage, durable damage,
  **AP**, fire rate, stagger, push — the enemy's offensive capability
- `Boosters` page → name, description, warbond, medal cost
- `Ship Modules` page → department, upgrade name, Common/Rare/Super/
  Requisition costs, effect, tier
- `Difficulty` page → per-level table: missions per operation, medal rewards,
  objectives, outposts, new enemies, new structures, multipliers
- `{{Damage}}` / `{{Armor}}` / `{{Difficulty}}` / `{{Currency}}` templates →
  damage types, armor tiers, difficulty names, currency amounts
- Prose sections (Tactical Information, Behavior, Spawning) pulled as a text
  corpus for the LLM to cite

A sync script walks a curated page list via `action=parse` (wikitext),
extracts the templates, normalizes to SQLite rows, and stores prose as text.
Re-scraped on demand when the wiki changes (game patches).

### Change tracking

Use the wiki's **RecentChanges feed** to find dirty pages, then re-scrape only
those. Mirrors the manual view you gave:
`Special:RecentChanges?hidebots=1&hidecategorization=1&limit=50&days=7`.

1. `action=query&list=recentchanges&rcshow=!bot&rcnamespace=0&rctype=edit|new&rclimit=50&rcdays=7&rctoponly=1&rcprop=title|ids|timestamp`
   → one batched call returns the newest change per page in the window
2. Intersect result titles against the curated page list; ignore pages with
   unchanged `pages.revision_id`
3. For changed pages only: pull wikitext (`action=parse`), re-extract
   templates into the wiki tables (`planets`/`weapons`/`weapon_attachments`/
   `stratagems`/`armor`/`boosters`/`warbonds`/`enemies`/`enemy_parts`/
   `enemy_attacks`/`missions`/`difficulties`/`ship_modules`), update prose,
   stamp the new revid
4. New/moved/renamed pages in the window are picked up (they appear as
   `new`); deleted pages are dropped from the curated list
5. `rctoponly=1` keeps only the newest change per page — no wasted re-scrapes
   from edit storms

The revid is still stored per page as the dedup key and the freshness stamp;
the feed just finds candidates more cheaply than polling every title.

A **mandatory hourly cron job** checks the RecentChanges feed so game-patch
wiki updates land without waiting for a chat query. This runs regardless of
usage.

## SQLite Schema

All data from the wiki scrape (revid-diffed):

- `planets` (index, name, sector, biome, conditions JSON) — static
  environmental conditions from `{{Infobox Planet}}`
- `weapons` (id, name, slot, category, type, damage, penetration_ap,
  capacity, recoil, fire_rate, dps, spare_mags, traits, firing_modes,
  scope_options, source, warbond_id)
- `weapon_attachments` (weapon_id, name, unlock_level, cost,
  effects JSON) — from `data_weapons.json`; effects keyed by the Lua's
  supported fields (ergonomics, optic_range, sway, recoil, spread,
  mag_capacity, reload)
- `stratagems` (id, name, permit_type, unlock_level, unlock_cost, traits,
  stratagem_code, call_time, uses, uses_upgraded, cooldown,
  cooldown_upgraded, rearm_time, rearm_time_upgraded, warbond_id)
- `armor` (id, name, type, armor_value, speed, stamina_regen, passive,
  cost, warbond_id)
- `boosters` (id, name, description, warbond_id, cost_medals)
- `enemy_attacks` (enemy_id, attack_name, damage, damage_durable, ap,
  fire_rate, stagger, push) — from `{{Enemy Loadout Box}}`
- `warbonds` (id, name, type, sc_cost, release_date, credit_claim,
  medal_total)
- `warbond_items` (warbond_id, page, item_name, item_type, cost_medals)
- `enemies` (id, name, faction, size, class, health, damage, damage_type,
  min_difficulty, fire_mult, stagger_req, rank, wiki_url)
- `enemy_parts` (enemy_id, part_name, health, armor_value, durability,
  percent_to_main, dmg_cap, bleed, fatal, exdr) — the penetration-zone table
- `missions` (id, name, faction, time_limit, min_difficulty, max_difficulty)
- `mission_objectives` (mission_id, step, description, reward)
- `difficulties` (level, name, missions_per_op, medal_rewards, objectives,
  outposts, multiplier) — enemy spawn lists live in `difficulty_scaling`
- `difficulty_scaling` (level, new_enemies, new_structures,
  new_main_objectives, new_side_objectives, notes)
- `ship_modules` (id, department, name, common_cost, rare_cost, super_cost,
  requisition_cost, effect, tier)
- `stratagem_modules` (stratagem_id, module_id, effect) — which ship modules
  buff which stratagem
- `pages` (title, revision_id, wikitext, prose, updated_at) — raw corpus for
  the LLM; `revision_id` drives change detection
- `synced_at` (source, timestamp) — cache freshness

## Chat Interaction

Free-form natural language. Agent infers intent and queries cache + knowledge:

```
what's good against chargers?
where's the weak point on a charger?
what can the senator penetrate?
what loadout works against Illuminate?
what does the Eradicate mission involve?
what difficulty do Bile Titans start spawning at?
how many enemies spawn on Helldive vs Super Helldive?
what's the biome and conditions on Malevelon Creek?
what's in the Polar Patriots warbond?
what primary comes from Democratic Detonation?
how much does the Polar Patriots warbond cost?
how many samples for the ship upgrade?
what does the 500kg bomb cost to unlock?
```

Answers cite the wiki page they came from and flag stale data.

## Profile

Isolated workspace, Discord-connected (same setup as food/workout bot). SQLite
DB in profile data dir. Wiki sync script runs on the mandatory hourly cron and
before answering when cache is stale.
