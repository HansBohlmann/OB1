-- ============================================================
-- Open Brain — Tier 1 entity kinds (company, property, area, decision)
-- Run in Supabase SQL Editor (project hngyvkxfclblzcobxatf)
-- Idempotent: safe to re-run.
--
-- What this does:
--   1. Replace entities.kind CHECK constraint to allow the four new kinds
--      (and keep the existing four).
--   2. Conservative backfill of obvious miscategorizations:
--        - 'NSL'           topic  → company
--        - 'JLL'           person → company
--        - '9 Mile project' topic → property
--        - 'Clarity88'     topic  → property
--      Only applies if no destination row already exists with the new kind
--      (would otherwise violate the (kind, normalized_name) UNIQUE constraint).
--   3. Update thought_entities.role to match the new kind for those rows so
--      future syncs don't recreate the old-kind variant.
--
-- Verification queries are at the bottom.
-- ============================================================

BEGIN;

-- =========================================================
-- 1. CHECK constraint replacement
-- =========================================================

ALTER TABLE entities DROP CONSTRAINT IF EXISTS entities_kind_check;

ALTER TABLE entities
  ADD CONSTRAINT entities_kind_check
  CHECK (kind IN (
    -- existing kinds
    'person', 'project', 'topic', 'concept',
    -- Tier 1 additions (2026-05-08)
    'company', 'property', 'area', 'decision'
  ));

-- =========================================================
-- 2. Conservative backfill of known misclassifications
-- =========================================================

-- Helper: reclassify ONE entity from (old_kind, name_pattern) to new_kind
-- - Skips if a destination row already exists (prevents UNIQUE violation)
-- - Updates linked thought_entities.role too so future syncs are coherent
CREATE OR REPLACE FUNCTION _reclassify_entity(
  p_old_kind text,
  p_name     text,
  p_new_kind text
) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  v_eid uuid;
  v_normalized text := lower(trim(p_name));
  v_dest_exists boolean;
BEGIN
  -- Find the source entity
  SELECT id INTO v_eid
    FROM entities
    WHERE kind = p_old_kind AND normalized_name = v_normalized;

  IF v_eid IS NULL THEN
    RETURN format('skip: no %s entity named %L', p_old_kind, p_name);
  END IF;

  -- Refuse if a destination row already exists (would collide on UNIQUE)
  SELECT EXISTS(
    SELECT 1 FROM entities
    WHERE kind = p_new_kind AND normalized_name = v_normalized
  ) INTO v_dest_exists;

  IF v_dest_exists THEN
    RETURN format('skip: %s:%s already exists — manual merge needed', p_new_kind, p_name);
  END IF;

  -- Reclassify
  UPDATE entities SET kind = p_new_kind WHERE id = v_eid;

  -- Keep thought_entities.role coherent with new kind so syncEntitiesForThought
  -- (which deletes-and-recreates links from metadata) finds the same entity row
  -- when the new extractor categorises this name into the matching metadata array.
  UPDATE thought_entities
    SET role = p_new_kind
    WHERE entity_id = v_eid AND role = p_old_kind;

  RETURN format('reclassified: %s:%s → %s:%s', p_old_kind, p_name, p_new_kind, p_name);
END $$;

DO $$
DECLARE
  msg text;
BEGIN
  -- Companies (orgs) currently filed as person or topic
  msg := _reclassify_entity('topic',  'NSL',             'company');  RAISE NOTICE '%', msg;
  msg := _reclassify_entity('person', 'JLL',             'company');  RAISE NOTICE '%', msg;

  -- Properties currently filed as topic
  msg := _reclassify_entity('topic',  '9 Mile project',  'property'); RAISE NOTICE '%', msg;
  msg := _reclassify_entity('topic',  'Clarity88',       'property'); RAISE NOTICE '%', msg;
END $$;

-- Drop helper after use (it's purpose-built and not part of the runtime API)
DROP FUNCTION IF EXISTS _reclassify_entity(text, text, text);

COMMIT;

-- ============================================================
-- VERIFICATION (run after the migration)
-- ============================================================
--
-- -- 1. Constraint accepts new kinds
-- SELECT pg_get_constraintdef(c.oid)
--   FROM pg_constraint c
--   WHERE c.conrelid = 'entities'::regclass AND c.conname = 'entities_kind_check';
--
-- -- 2. Reclassified rows landed in the right place
-- SELECT kind, name, mention_count
-- FROM entities
-- WHERE name IN ('NSL', 'JLL', '9 Mile project', 'Clarity88')
-- ORDER BY name;
--
-- -- 3. thought_entities role keeps step
-- SELECT te.role, e.kind, e.name, count(*) AS link_count
-- FROM thought_entities te
-- JOIN entities e ON e.id = te.entity_id
-- WHERE e.name IN ('NSL', 'JLL', '9 Mile project', 'Clarity88')
-- GROUP BY te.role, e.kind, e.name
-- ORDER BY e.name;
--
-- -- 4. Total entity counts by kind (sanity)
-- SELECT kind, count(*) FROM entities GROUP BY kind ORDER BY 1;
-- ============================================================
