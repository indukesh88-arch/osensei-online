-- Fix bot Season-card collection detection.
-- Season cards have IDs too, so collection must be gated by category,
-- not by whether the selected card ID is NULL.

DO $migration$
DECLARE
  v_definition text;
  v_old text := 'IF v_collection_kind IS NULL AND jsonb_array_length(v_pile) > 0';
  v_new text := 'IF v_card->>''category'' = ''season'' AND jsonb_array_length(v_pile) > 0';
BEGIN
  SELECT pg_get_functiondef('public.run_bot_turn(uuid)'::regprocedure)
  INTO v_definition;

  IF position(v_old IN v_definition) = 0 THEN
    RAISE EXCEPTION 'Expected bot Season collection condition was not found; no function was changed.';
  END IF;

  v_definition := replace(v_definition, v_old, v_new);
  EXECUTE v_definition;
END;
$migration$;
