# Health-check MCP — `mcps/health_check/`

Cal-in + cal-out + weight. Minimal schemas (old `food_*` abandoned, no migration):

- `hc_meals`: `date`, `items[{name, qty?, kcal, protein, carbs, fat, fiber}]`,
  `totals` (computed), `createdAt`. Agent parses text → MCP validates, naming
  any missing macro field.
- `hc_weight`: `date` (unique), `kg`, `createdAt`. Never pruned.
- `hc_days`: `date` (unique), `steps`, `active_kcal`, `sleep_hours`,
  `workouts[{type, minutes, kcal}]`, `updatedAt`. One doc per date — MCP and
  health-api write the same shape (no field drift).

Run: `PYTHONPATH=mcps pip install -r mcps/health_check/requirements.txt`,
needs `MONGODB_URI`/`MONGODB_DB`, then `python mcps/health_check/server.py` (stdio).
In-container `PYTHONPATH=/mcps`.
