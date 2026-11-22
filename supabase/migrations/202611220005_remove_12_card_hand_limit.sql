-- Remove the 12-card hand limit for humans and bots.
-- This version edits deparsed PostgreSQL function definitions, so it does not
-- depend on comments that pg_get_functiondef omits.

DO $migration$
DECLARE
  v_def text;
  v_new text;
BEGIN
  -- Human draw: remove the full-hand early return.
  SELECT pg_get_functiondef('public.draw_game_card(uuid)'::regprocedure) INTO v_def;
  v_new := regexp_replace(
    v_def,
    'IF[[:space:]]+jsonb_array_length\(v_hand\)[[:space:]]*>=[[:space:]]*12[[:space:]]+THEN[\s\S]*?END IF;',
    '',
    'i'
  );
  IF v_new = v_def THEN
    RAISE EXCEPTION 'Could not locate the human full-hand draw restriction in draw_game_card.';
  END IF;
  v_def := v_new;

  v_new := regexp_replace(
    v_def,
    'v_draw_count[[:space:]]*:=[[:space:]]*LEAST\(v_draw_count,[[:space:]]*12[[:space:]]*-[[:space:]]*jsonb_array_length\(v_hand\)\);',
    '',
    'i'
  );
  IF v_new = v_def THEN
    RAISE EXCEPTION 'Could not locate the human draw-count cap in draw_game_card.';
  END IF;
  EXECUTE v_new;

  -- Bot draw and collection: remove draw cap and make collection capacity unlimited.
  SELECT pg_get_functiondef('public.run_bot_turn(uuid)'::regprocedure) INTO v_def;
  v_new := regexp_replace(
    v_def,
    'v_draw_count[[:space:]]*:=[[:space:]]*LEAST\(v_draw_count,[[:space:]]*12[[:space:]]*-[[:space:]]*v_hand_count\);',
    '',
    'i'
  );
  IF v_new = v_def THEN
    RAISE EXCEPTION 'Could not locate the bot draw-count cap in run_bot_turn.';
  END IF;
  v_def := v_new;

  v_new := regexp_replace(
    v_def,
    'IF[[:space:]]+v_hand_count[[:space:]]*<[[:space:]]*12[[:space:]]+THEN[\s\S]*?END IF;',
    'FOR v_i IN 1..v_draw_count LOOP
      EXIT WHEN jsonb_array_length(v_deck) = 0;
      v_card := v_deck -> 0;
      v_deck := v_deck - 0;
      v_hand := v_hand || jsonb_build_array(v_card);
    END LOOP;',
    'i'
  );
  IF v_new = v_def THEN
    RAISE EXCEPTION 'Could not locate the bot full-hand draw block in run_bot_turn.';
  END IF;
  v_def := v_new;

  v_new := regexp_replace(
    v_def,
    'v_capacity[[:space:]]*:=[[:space:]]*GREATEST\(0,[[:space:]]*13[[:space:]]*-[[:space:]]*v_hand_count\);',
    'v_capacity := 2147483647;',
    'i'
  );
  IF v_new = v_def THEN
    RAISE EXCEPTION 'Could not locate the bot collection capacity in run_bot_turn.';
  END IF;
  EXECUTE v_new;

  -- Sakura Leaf: remove its human hand-size rejection.
  SELECT pg_get_functiondef('public.play_sakura_leaf(uuid,text,jsonb)'::regprocedure) INTO v_def;
  v_new := regexp_replace(
    v_def,
    'IF[[:space:]]+jsonb_array_length\(v_new_hand\)[[:space:]]*>[[:space:]]*12[[:space:]]+THEN[\s\S]*?END IF;',
    '',
    'i'
  );
  IF v_new = v_def THEN
    RAISE EXCEPTION 'Could not locate Sakura Leaf hand limit.';
  END IF;
  EXECUTE v_new;

  -- Tengu: remove its human hand-size rejection.
  SELECT pg_get_functiondef('public.play_tengu(uuid,text,uuid,jsonb)'::regprocedure) INTO v_def;
  v_new := regexp_replace(
    v_def,
    'IF[[:space:]]+jsonb_array_length\(v_hand\)[[:space:]]*>[[:space:]]*12[[:space:]]+THEN[\s\S]*?END IF;',
    '',
    'i'
  );
  IF v_new = v_def THEN
    RAISE EXCEPTION 'Could not locate Tengu hand limit.';
  END IF;
  EXECUTE v_new;
END;
$migration$;
