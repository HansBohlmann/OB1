# 2026-05-08 — Tier 1 entity kinds + user tags

Bundled deploy: extends `entities.kind` with four new values (`company`, `property`, `area`, `decision`) and adds user-applied `#hashtag` extraction into `metadata.tags`.

## What ships

**Schema (SQL)**
- `docs/deploys/2026-05-08-tier1-entity-kinds.sql` — replaces the `entities_kind_check` constraint and conservatively reclassifies four known misfiled entities (NSL/JLL/9 Mile project/Clarity88).

**Edge Functions (deployed-only — supabase/ is gitignored, see `reference_ob1_gitignore.md`)**
- `supabase/functions/ingest-thought/index.ts`
  - extractor prompt now follows Editorial Policy v1.2 with the most-specific-kind rule (R2.5)
  - new metadata arrays: `companies`, `properties`, `areas`, `decisions`
  - hashtag parser pulls `#tag` and `#thread/x` from typed text into `metadata.tags`
  - `syncEntitiesForThought` upserts the four new kinds into the entities graph
  - Slack confirmation reply includes companies/properties/areas/decisions/tags lines
- `supabase/functions/open-brain-mcp/index.ts`
  - extractor brought to v1.2 parity (was lagging the ingest-thought version)
  - same hashtag parser; `capture_thought` now writes `metadata.tags` and surfaces them in the confirmation
  - `list_thoughts` gains filters: `tag`, `company`, `property`, `area`, `decision`
  - `list_entities`, `entity_thoughts`, `entity_neighbors` `kind` enums extended to all 8 kinds
  - server version bumped to 1.2.0

**Policy**
- `docs/editorial-policy.md` → v1.2: adds R2.4 (entity kinds table), R2.5 (most-specific-kind rule), R2.6 (hashtag tag rules — never auto-generate, preserve case and slashes).

## Deploy steps

Run from your terminal at `~/Documents/Claude/Projects/Open Brain /OB1`:

```bash
# 1. SQL migration — paste the file contents into the Supabase SQL editor
#    https://supabase.com/dashboard/project/hngyvkxfclblzcobxatf/sql/new
#    Source: docs/deploys/2026-05-08-tier1-entity-kinds.sql

# 2. Edge Function deploys (independent of git — supabase/ is gitignored)
cd "/Users/hansbohlmann/Documents/Claude/Projects/Open Brain /OB1"
supabase functions deploy ingest-thought --no-verify-jwt
supabase functions deploy open-brain-mcp
```

`ingest-thought` keeps `--no-verify-jwt` because it receives unauthenticated Slack events. `open-brain-mcp` enforces auth via the `x-brain-key` header, so it's deployed with default JWT settings.

## Verification

After deploy, ping Claude (or any MCP client) with these:

```
list_entities(kind="company")        → should include NSL, JLL
list_entities(kind="property")       → should include 9 Mile project, Clarity88
list_thoughts(tag="#test-tag", limit=5)   → empty until you post a tagged thought
```

Then post a one-off Slack capture in `#capture` like:

```
Spoke to Sarah at JLL today about the 9 Mile valuation. #thesis #thread/property-strategy
```

Expected outcome:
- Slack reply lists People: Sarah · Companies: JLL · Properties: 9 Mile · Tags: #thesis #thread/property-strategy
- `list_entities(kind="property", search="9 Mile")` shows the entity
- `list_thoughts(tag="#thesis")` returns the new thought
- `entity_thoughts(entity_name="JLL", kind="company")` returns the new thought

## Rollback

The SQL migration is idempotent and additive — to revert, drop the constraint and re-add the original:

```sql
ALTER TABLE entities DROP CONSTRAINT entities_kind_check;
ALTER TABLE entities
  ADD CONSTRAINT entities_kind_check
  CHECK (kind IN ('person', 'project', 'topic', 'concept'));
-- Note: this will fail if any rows already have one of the new kinds.
-- In that case, reclassify them back to topic first.
```

Edge Functions can be rolled back by redeploying the prior versions (recoverable via `supabase functions download <name>` from a known-good environment, or git history of any branch where they were tracked).

## Why this set, why now

Four entity kinds (R2.4) were the queued Tier 1 from `project_next_session_entity_kinds.md`. Tags (R2.6) were a same-day add Hans flagged after the strategic OB-vs-PARA decision: the cheap path (hashtags-in-capture-text → metadata) is small enough to count as completing the metadata model rather than starting a new feature line. After this lands the system is on a deliberate 60-day no-new-features hold to let the synthesis layer accumulate longitudinal signal.
