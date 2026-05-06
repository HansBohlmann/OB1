# Open Brain — May 2026 Capability Expansion Deploy Log

**Date deployed:** 2026-05-06
**Branch:** `expand-capability`
**Supabase project:** `hngyvkxfclblzcobxatf`
**Source runbook:** `~/Documents/Claude/Projects/Open Brain / Second Brain/ob1-expansion/RUNBOOK.md`

## What shipped

Four additive capability expansions to the single-table-vector-DB design:

1. **Hybrid search** — `thoughts.content_tsv` generated tsvector column + GIN index, with `hybrid_search_thoughts()` combining cosine and lexical ranks via RRF.
2. **Graph layer** — `entities` (person/project/topic/concept) + `thought_entities` join table; backfilled from existing `metadata.people` / `metadata.topics`.
3. **Attachments** — `attachments` table + private `thought-attachments` Storage bucket; ingest pipeline downloads Slack files, upserts to Storage, OCRs images via gpt-4o-mini vision, transcribes audio via Whisper (gated on `OPENAI_API_KEY`, currently unset).
4. **Temporal helpers** — `thought_volume_by_period()`, `topic_trends_by_period()`, `entity_activity()`.

All DB changes additive: no `DROP`, no `ALTER` of existing columns. `thoughts` schema, `match_thoughts`, `upsert_thought` untouched. Existing morning-briefing / weekly-summary flows continue working.

Migration SQL preserved at `docs/deploys/2026-05-06-expand-capability.sql` (byte-identical to the staged copy).

## Edge Function changes

- **`ingest-thought`** — adds background processing (`EdgeRuntime.waitUntil` for fast 200 ack), attachment pipeline, entity sync, captures attachment-only messages.
- **`open-brain-mcp`** — `search_thoughts` upgrades to hybrid with `mode: hybrid|vector|lexical`; `capture_thought` now links entities; 4 new tools: `list_entities`, `entity_thoughts`, `entity_neighbors`, `temporal_summary`.

Both deployed with `--no-verify-jwt`.

## Verification (smoke tests, all ✓)

- Migration verification queries 1.1–1.6 all passed.
- Entity backfill: 36 persons, 328 topics. Top 5 persons: Hans 68 / Lyle Daniels 5 / Rose 5 / Bryan Ame 4 / Maul Malken 4.
- Hybrid search RRF working (sem 24.1% + lex 0.061 + hybrid 0.028 ordering on test query).
- Mode toggle visibly changes ranking (hybrid vs lexical).
- Entity tools (`list_entities`, `entity_thoughts`, `entity_neighbors`) return populated, accurate results.
- Temporal summary: volume curve last 5 weeks 9 / 21 / 7 / 39 / 26.
- Image attachment pipeline: Mac PNG round-trips through Storage + gpt-4o-mini vision OCR; threaded reply shows `Attachments: image ✓`; `attachments.extraction_status='completed'` with verbatim text + factual description in `extracted_text`.
- Audio attachment path not tested (Superwhisper handles voice locally; `OPENAI_API_KEY` intentionally unset → audio attachments would land with `extraction_status='skipped'`).

## Bug fixes applied during deploy

The runbook had two latent bugs that surfaced during smoke test 3.5 (image attachment). Both were fixed in `supabase/functions/ingest-thought/index.ts` and re-deployed.

### Bug 1 — `file_share` subtype filter

- **Symptom:** image attachments dropped to `#capture` returned HTTP 200 with **zero log output**; `processCapture` never ran.
- **Root cause:** the HTTP entrypoint's event filter rejected *any* truthy `event.subtype`. Slack uses `subtype: "file_share"` for messages with file uploads, so file-bearing messages short-circuited at the front door before reaching capture.
- **Fix:** narrow the rejection rule to ignore only subtypes *other than* `"file_share"`. Plain text (no subtype) and file uploads (`subtype="file_share"`) both pass; `message_changed`, `message_deleted`, `bot_message`, etc. still rejected.

### Bug 2 — manual base64 encoding corrupting binary data

- **Symptom:** after Bug 1's fix, the same Mac PNG (130573 bytes, validated valid PNG on disk) reached `describeImage` but OpenRouter returned `400 unsupported image format`.
- **Root cause:** `describeImage` used a hand-rolled `for (i…) bin += String.fromCharCode(buf[i]); btoa(bin)` to base64-encode the image bytes. This pattern is fragile for binary data on Deno — large buffers can produce malformed Latin-1 strings, and `btoa` happily emits invalid base64 from them without erroring. The result is a syntactically-valid data URI containing corrupted base64 that the upstream API rejects.
- **Fix:** import `encodeBase64` from `https://deno.land/std@0.224.0/encoding/base64.ts` and pass the `Uint8Array` directly — no string round-trip. Also added a one-line diagnostic `console.log` capturing first-8-byte magic, total bytes, base64 length, and data URI prefix to `describeImage`, to make future failures observable rather than silent.

**Lesson for future deploys:** any code that encodes binary data via `String.fromCharCode` + `btoa` should be replaced with `encodeBase64` (Deno) or `Buffer.from(...).toString('base64')` (Node). The hand-rolled pattern looks correct but is broken in subtle, size-dependent ways.

## Rollback

The deployed function code's prior version is preserved as on-disk artifacts (outside the OB1 repo, so untouched by `supabase/` gitignore):

- `~/Documents/Claude/Projects/Open Brain / Second Brain/ob1-expansion/_prev/ingest-thought.OLD.ts` (10422 bytes — pulled from Supabase via `supabase functions download` immediately before Step 2.2 deploy; byte-identical to the live code at that moment)
- `~/Documents/Claude/Projects/Open Brain / Second Brain/ob1-expansion/_prev/open-brain-mcp.OLD.ts` (17200 bytes — pulled from Supabase via `supabase functions download` immediately before Step 2.2 deploy; byte-identical to the live code at that moment)

To roll back the function deploys:

```bash
cp ~/Documents/Claude/Projects/"Open Brain "/" Second Brain"/ob1-expansion/_prev/ingest-thought.OLD.ts \
   supabase/functions/ingest-thought/index.ts
cp ~/Documents/Claude/Projects/"Open Brain "/" Second Brain"/ob1-expansion/_prev/open-brain-mcp.OLD.ts \
   supabase/functions/open-brain-mcp/index.ts
supabase functions deploy ingest-thought  --project-ref hngyvkxfclblzcobxatf --no-verify-jwt
supabase functions deploy open-brain-mcp  --project-ref hngyvkxfclblzcobxatf --no-verify-jwt
```

If the `_prev/` artifacts are ever lost, the deployed code is also pullable from Supabase at any time:

```bash
supabase functions download <name> --project-ref hngyvkxfclblzcobxatf
```

DB rollback **not needed** — all schema changes are additive, leaving them in place is harmless. Destructive rollback SQL (if ever desired) is in the runbook's "Rollback" section.

## Known limitations / follow-ups

- **PDF extraction stubbed.** PDFs land in Storage with `extraction_status='unsupported'`. Wiring up extraction (likely OpenAI Responses API with file input, or a Deno PDF parser) is a clean follow-up.
- **No re-embedding on metadata correction.** Thread-reply corrections update metadata but the embedding still reflects the original content. Matters only when a corrected `topics` would meaningfully shift retrieval.
- **No background entity merge.** "Lyle" and "Lyle Daniels" appearing in metadata produce two entities; deduping is a candidate for a small admin tool later.
- **Hybrid weights uniform.** `semantic_weight=lexical_weight=1` works well as a default; corpus-specific tuning may help.
- **Staging artifact out of sync.** `~/Documents/Claude/Projects/Open Brain / Second Brain/ob1-expansion/02-ingest-thought.ts` still contains both bugs from the runbook; sync from `supabase/functions/ingest-thought/index.ts` next time the deploy artifacts are touched.
- **`supabase/` is in `.gitignore`.** Deployed function code lives entirely outside git history. Revisit this policy as separate work — current deploy honored the existing convention.
- **Diagnostic `console.log` in `describeImage` left in place.** Captures magic bytes / b64 length for future debugging. Remove or guard with a `DEBUG_ATTACHMENTS` env var once the attachment pipeline is proven stable in production.

## References

- Source runbook: `~/Documents/Claude/Projects/Open Brain / Second Brain/ob1-expansion/RUNBOOK.md`
- Migration SQL (this deploy): `docs/deploys/2026-05-06-expand-capability.sql`
- Project ref: `hngyvkxfclblzcobxatf`
- Slack capture channel: env var `SLACK_CAPTURE_CHANNEL`
- MCP authentication: `x-brain-key` header, secret `MCP_ACCESS_KEY`
