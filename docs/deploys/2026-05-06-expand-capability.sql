-- ============================================================
-- Open Brain capability expansion — fills 4 gaps
-- Run in Supabase SQL Editor (project hngyvkxfclblzcobxatf)
-- Idempotent: safe to re-run.
--
-- Sections
--   1. Hybrid search (tsvector + RRF)
--   2. Entities + thought_entities join (graph layer)
--   3. Attachments table + storage bucket
--   4. Temporal helper functions
--
-- Verification queries are at the bottom.
-- ============================================================

BEGIN;

-- =========================================================
-- 1. HYBRID SEARCH — tsvector + GIN + RRF combiner
-- =========================================================

-- Generated tsvector column. Uses 'english' as a regconfig literal
-- so the expression stays IMMUTABLE (required for STORED columns).
ALTER TABLE thoughts
  ADD COLUMN IF NOT EXISTS content_tsv tsvector
  GENERATED ALWAYS AS (to_tsvector('english'::regconfig, coalesce(content, ''))) STORED;

CREATE INDEX IF NOT EXISTS thoughts_content_tsv_idx
  ON thoughts USING gin (content_tsv);

-- Reciprocal Rank Fusion combiner.
-- Pulls top `candidate_pool` from semantic (cosine) and lexical (ts_rank),
-- combines via 1/(k+rank) then returns top `match_count`.
CREATE OR REPLACE FUNCTION hybrid_search_thoughts(
  query_text       text,
  query_embedding  vector(1536),
  match_count      int    DEFAULT 10,
  rrf_k            int    DEFAULT 60,
  semantic_weight  float  DEFAULT 1.0,
  lexical_weight   float  DEFAULT 1.0,
  candidate_pool   int    DEFAULT 50,
  filter           jsonb  DEFAULT '{}'::jsonb
) RETURNS TABLE (
  id            uuid,
  content       text,
  metadata      jsonb,
  created_at    timestamptz,
  similarity    float,
  lexical_rank  float,
  hybrid_score  float
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_tsq tsquery;
BEGIN
  -- Guard: empty/whitespace query → skip lexical leg, fall back to pure semantic.
  v_tsq := CASE
             WHEN trim(coalesce(query_text, '')) = '' THEN NULL
             ELSE websearch_to_tsquery('english'::regconfig, query_text)
           END;

  RETURN QUERY
  WITH semantic AS (
    SELECT
      t.id,
      t.content,
      t.metadata,
      t.created_at,
      1 - (t.embedding <=> query_embedding) AS similarity,
      ROW_NUMBER() OVER (ORDER BY t.embedding <=> query_embedding) AS rnk
    FROM thoughts t
    WHERE t.embedding IS NOT NULL
      AND (filter = '{}'::jsonb OR t.metadata @> filter)
    ORDER BY t.embedding <=> query_embedding
    LIMIT candidate_pool
  ),
  lexical AS (
    SELECT
      t.id,
      t.content,
      t.metadata,
      t.created_at,
      ts_rank(t.content_tsv, v_tsq) AS lex_score,
      ROW_NUMBER() OVER (ORDER BY ts_rank(t.content_tsv, v_tsq) DESC) AS rnk
    FROM thoughts t
    WHERE v_tsq IS NOT NULL
      AND t.content_tsv @@ v_tsq
      AND (filter = '{}'::jsonb OR t.metadata @> filter)
    ORDER BY lex_score DESC
    LIMIT candidate_pool
  ),
  combined AS (
    SELECT
      COALESCE(s.id, l.id)                                     AS id,
      COALESCE(s.content, l.content)                           AS content,
      COALESCE(s.metadata, l.metadata)                         AS metadata,
      COALESCE(s.created_at, l.created_at)                     AS created_at,
      COALESCE(s.similarity, 0)::float                         AS similarity,
      COALESCE(l.lex_score, 0)::float                          AS lexical_rank,
      ( CASE WHEN s.rnk IS NOT NULL THEN semantic_weight / (rrf_k + s.rnk)::float ELSE 0 END
      + CASE WHEN l.rnk IS NOT NULL THEN lexical_weight  / (rrf_k + l.rnk)::float ELSE 0 END
      )::float                                                 AS hybrid_score
    FROM semantic s
    FULL OUTER JOIN lexical l ON s.id = l.id
  )
  SELECT c.id, c.content, c.metadata, c.created_at, c.similarity, c.lexical_rank, c.hybrid_score
  FROM combined c
  ORDER BY c.hybrid_score DESC
  LIMIT match_count;
END;
$$;

-- =========================================================
-- 2. ENTITIES + JOIN TABLE — graph layer (relational)
-- =========================================================

CREATE TABLE IF NOT EXISTS entities (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind            text NOT NULL CHECK (kind IN ('person', 'project', 'topic', 'concept')),
  name            text NOT NULL,
  normalized_name text GENERATED ALWAYS AS (lower(trim(name))) STORED,
  metadata        jsonb DEFAULT '{}'::jsonb,
  first_seen_at   timestamptz DEFAULT now(),
  last_seen_at    timestamptz DEFAULT now(),
  mention_count   integer DEFAULT 0,
  CONSTRAINT entities_kind_name_uniq UNIQUE (kind, normalized_name)
);

CREATE INDEX IF NOT EXISTS entities_kind_idx       ON entities (kind);
CREATE INDEX IF NOT EXISTS entities_last_seen_idx  ON entities (last_seen_at DESC);

CREATE TABLE IF NOT EXISTS thought_entities (
  thought_id  uuid NOT NULL REFERENCES thoughts(id)  ON DELETE CASCADE,
  entity_id   uuid NOT NULL REFERENCES entities(id)  ON DELETE CASCADE,
  role        text NOT NULL DEFAULT 'mention',
  created_at  timestamptz DEFAULT now(),
  PRIMARY KEY (thought_id, entity_id, role)
);

CREATE INDEX IF NOT EXISTS thought_entities_entity_idx  ON thought_entities (entity_id, created_at DESC);
CREATE INDEX IF NOT EXISTS thought_entities_thought_idx ON thought_entities (thought_id);

ALTER TABLE entities         ENABLE ROW LEVEL SECURITY;
ALTER TABLE thought_entities ENABLE ROW LEVEL SECURITY;

-- Idempotent upsert helper: returns the entity id; bumps mention_count + last_seen_at.
-- Returns NULL for blank input so callers can skip cleanly.
CREATE OR REPLACE FUNCTION upsert_entity(p_kind text, p_name text)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_id         uuid;
  v_normalized text := lower(trim(coalesce(p_name, '')));
BEGIN
  IF v_normalized = '' THEN
    RETURN NULL;
  END IF;

  INSERT INTO entities (kind, name)
  VALUES (p_kind, trim(p_name))
  ON CONFLICT (kind, normalized_name) DO UPDATE
    SET last_seen_at  = now(),
        mention_count = entities.mention_count + 1
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- Backfill from existing thoughts.metadata.people / metadata.topics.
-- Safe to re-run: the join-table inserts are ON CONFLICT DO NOTHING, and the
-- final UPDATE recomputes mention_count from the join table, so re-running
-- never double-counts.
DO $$
DECLARE
  r           record;
  person_name text;
  topic_name  text;
  v_eid       uuid;
BEGIN
  FOR r IN SELECT id, metadata, created_at FROM thoughts LOOP
    -- People
    IF jsonb_typeof(r.metadata->'people') = 'array' THEN
      FOR person_name IN SELECT jsonb_array_elements_text(r.metadata->'people') LOOP
        v_eid := upsert_entity('person', person_name);
        IF v_eid IS NOT NULL THEN
          INSERT INTO thought_entities (thought_id, entity_id, role, created_at)
          VALUES (r.id, v_eid, 'person', r.created_at)
          ON CONFLICT DO NOTHING;
        END IF;
      END LOOP;
    END IF;

    -- Topics
    IF jsonb_typeof(r.metadata->'topics') = 'array' THEN
      FOR topic_name IN SELECT jsonb_array_elements_text(r.metadata->'topics') LOOP
        v_eid := upsert_entity('topic', topic_name);
        IF v_eid IS NOT NULL THEN
          INSERT INTO thought_entities (thought_id, entity_id, role, created_at)
          VALUES (r.id, v_eid, 'topic', r.created_at)
          ON CONFLICT DO NOTHING;
        END IF;
      END LOOP;
    END IF;
  END LOOP;

  -- Recompute mention_count from the join table to undo any double-counting
  -- caused by re-running the backfill on already-joined rows.
  UPDATE entities e
  SET mention_count = sub.cnt
  FROM (
    SELECT entity_id, COUNT(*)::int AS cnt
    FROM thought_entities
    GROUP BY entity_id
  ) sub
  WHERE e.id = sub.entity_id;
END $$;

-- Graph query helpers ---------------------------------------------------------

CREATE OR REPLACE FUNCTION entity_thoughts(p_entity_id uuid, p_limit int DEFAULT 25)
RETURNS TABLE (id uuid, content text, metadata jsonb, created_at timestamptz, role text)
LANGUAGE sql STABLE AS $$
  SELECT t.id, t.content, t.metadata, t.created_at, te.role
  FROM thought_entities te
  JOIN thoughts t ON t.id = te.thought_id
  WHERE te.entity_id = p_entity_id
  ORDER BY t.created_at DESC
  LIMIT p_limit;
$$;

CREATE OR REPLACE FUNCTION entity_neighbors(p_entity_id uuid, p_limit int DEFAULT 20)
RETURNS TABLE (id uuid, kind text, name text, co_mention_count bigint)
LANGUAGE sql STABLE AS $$
  SELECT e.id, e.kind, e.name, COUNT(*)::bigint AS co_mention_count
  FROM thought_entities a
  JOIN thought_entities b ON a.thought_id = b.thought_id AND a.entity_id <> b.entity_id
  JOIN entities e ON e.id = b.entity_id
  WHERE a.entity_id = p_entity_id
  GROUP BY e.id, e.kind, e.name
  ORDER BY co_mention_count DESC
  LIMIT p_limit;
$$;

-- =========================================================
-- 3. ATTACHMENTS — table + storage bucket
-- =========================================================

CREATE TABLE IF NOT EXISTS attachments (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  thought_id         uuid REFERENCES thoughts(id) ON DELETE CASCADE,
  storage_path       text NOT NULL,
  kind               text NOT NULL CHECK (kind IN ('audio', 'image', 'pdf', 'other')),
  mime_type          text,
  original_filename  text,
  size_bytes         bigint,
  extracted_text     text,
  extraction_status  text DEFAULT 'pending'
                     CHECK (extraction_status IN ('pending','completed','failed','skipped','unsupported')),
  extraction_error   text,
  created_at         timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS attachments_thought_idx ON attachments (thought_id);
CREATE INDEX IF NOT EXISTS attachments_kind_idx    ON attachments (kind);

ALTER TABLE attachments ENABLE ROW LEVEL SECURITY;

-- Private storage bucket for raw files (idempotent).
INSERT INTO storage.buckets (id, name, public)
VALUES ('thought-attachments', 'thought-attachments', false)
ON CONFLICT (id) DO NOTHING;

-- =========================================================
-- 4. TEMPORAL HELPERS — volume / topic trends / entity activity
-- =========================================================

CREATE OR REPLACE FUNCTION thought_volume_by_period(
  p_period text         DEFAULT 'day',
  p_since  timestamptz  DEFAULT now() - interval '90 days'
) RETURNS TABLE (period_start timestamptz, count bigint)
LANGUAGE sql STABLE AS $$
  SELECT date_trunc(p_period, created_at) AS period_start, COUNT(*)::bigint
  FROM thoughts
  WHERE created_at >= p_since
  GROUP BY 1
  ORDER BY 1 DESC;
$$;

CREATE OR REPLACE FUNCTION topic_trends_by_period(
  p_period text         DEFAULT 'week',
  p_since  timestamptz  DEFAULT now() - interval '90 days',
  p_top_n  int          DEFAULT 5
) RETURNS TABLE (period_start timestamptz, name text, count bigint)
LANGUAGE sql STABLE AS $$
  WITH ranked AS (
    SELECT
      date_trunc(p_period, t.created_at) AS period_start,
      e.name,
      COUNT(*)::bigint AS count,
      ROW_NUMBER() OVER (
        PARTITION BY date_trunc(p_period, t.created_at)
        ORDER BY COUNT(*) DESC
      ) AS rnk
    FROM thoughts t
    JOIN thought_entities te ON te.thought_id = t.id
    JOIN entities e          ON e.id          = te.entity_id
    WHERE t.created_at >= p_since
      AND e.kind = 'topic'
    GROUP BY 1, 2
  )
  SELECT period_start, name, count
  FROM ranked
  WHERE rnk <= p_top_n
  ORDER BY period_start DESC, count DESC;
$$;

CREATE OR REPLACE FUNCTION entity_activity(
  p_entity_id uuid,
  p_period    text         DEFAULT 'week',
  p_since     timestamptz  DEFAULT now() - interval '180 days'
) RETURNS TABLE (period_start timestamptz, count bigint)
LANGUAGE sql STABLE AS $$
  SELECT date_trunc(p_period, t.created_at) AS period_start, COUNT(*)::bigint
  FROM thought_entities te
  JOIN thoughts t ON t.id = te.thought_id
  WHERE te.entity_id = p_entity_id
    AND t.created_at >= p_since
  GROUP BY 1
  ORDER BY 1 DESC;
$$;

COMMIT;

-- ============================================================
-- VERIFICATION (run after the migration)
-- ============================================================
--
-- -- 1. Hybrid search smoke test
-- SELECT id, similarity, lexical_rank, hybrid_score, left(content, 80)
-- FROM hybrid_search_thoughts(
--   'governance',
--   (SELECT embedding FROM thoughts WHERE embedding IS NOT NULL LIMIT 1),
--   5
-- );
--
-- -- 2. Entity counts (should match metadata totals roughly)
-- SELECT kind, COUNT(*) FROM entities GROUP BY kind;
-- SELECT name, mention_count FROM entities WHERE kind='person' ORDER BY mention_count DESC LIMIT 5;
--
-- -- 3. Entity neighbours for the top person
-- SELECT * FROM entity_neighbors(
--   (SELECT id FROM entities WHERE kind='person' ORDER BY mention_count DESC LIMIT 1)
-- );
--
-- -- 4. Storage bucket exists
-- SELECT id, name, public FROM storage.buckets WHERE id='thought-attachments';
--
-- -- 5. Temporal: thoughts per day, last 30 days
-- SELECT * FROM thought_volume_by_period('day', now() - interval '30 days');
--
-- -- 6. Temporal: top 3 topics per week, last 60 days
-- SELECT * FROM topic_trends_by_period('week', now() - interval '60 days', 3);
-- ============================================================
