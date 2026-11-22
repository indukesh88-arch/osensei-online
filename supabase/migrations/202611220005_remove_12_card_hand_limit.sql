-- Remove the 12-card hand limit for every player, including bots.
-- Drawing, card collection, Sakura Leaf and Tengu may now increase hand size
-- without an artificial cap. Normal draw rules and card effects are unchanged.

DO $migration$
DECLARE
  v_def text;
  v_old text;
BEGIN
  -- Human turn draw: remove the full-hand skip and draw-count cap.
  SELECT pg_get_functiondef('public.draw_game_card(uuid)'::regprocedure) INTO v_def;
  v_old := $old$  -- A full hand skips the draw, but the reshuffle above still happens before
  -- the turn proceeds, and this turn is marked as processed.
  IF jsonb_array_length(v_hand) >= 12 THEN
    UPDATE public.player_hands
      SET last_draw_turn_number = v_turn_number, updated_at = now()
    WHERE room_id = p_room_id AND room_player_id = v_player_id;

    UPDATE public.game_states
      SET draw_deck = v_deck,
          open_pile = v_open_pile,
          updated_at = now()
    WHERE room_id = p_room_id;

    RETURN jsonb_build_object(
      'success', true,
      'cards_in_hand', jsonb_array_length(v_hand),
      'cards_drawn', 0,
      'cards_remaining', jsonb_array_length(v_deck),
      'reshuffled', v_reshuffled
    );
  END IF;

$old$;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'Could not locate the human full-hand draw restriction.';
  END IF;
  v_def := replace(v_def, v_old, '');
  v_old := '  v_draw_count := LEAST(v_draw_count, 12 - jsonb_array_length(v_hand));';
  IF position(v_old IN v_def) = 0 THEN RAISE EXCEPTION 'Could not locate human draw cap.'; END IF;
  v_def := replace(v_def, v_old, '');
  EXECUTE v_def;

  -- Bot turn: remove draw and collection capacity restrictions.
  SELECT pg_get_functiondef('public.run_bot_turn(uuid)'::regprocedure) INTO v_def;
  v_old := '  v_draw_count := LEAST(v_draw_count, 12 - v_hand_count);';
  IF position(v_old IN v_def) = 0 THEN RAISE EXCEPTION 'Could not locate bot draw cap.'; END IF;
  v_def := replace(v_def, v_old, '');
  v_old := $old$  IF v_hand_count < 12 THEN
    FOR v_i IN 1..v_draw_count LOOP
      EXIT WHEN jsonb_array_length(v_deck) = 0;
      EXIT WHEN jsonb_array_length(v_hand) >= 12;
      v_card := v_deck -> 0;
      v_deck := v_deck - 0;
      v_hand := v_hand || jsonb_build_array(v_card);
    END LOOP;
  END IF;

$old$;
  IF position(v_old IN v_def) = 0 THEN RAISE EXCEPTION 'Could not locate bot draw limit block.'; END IF;
  v_def := replace(v_def, v_old, $new$  FOR v_i IN 1..v_draw_count LOOP
    EXIT WHEN jsonb_array_length(v_deck) = 0;
    v_card := v_deck -> 0;
    v_deck := v_deck - 0;
    v_hand := v_hand || jsonb_build_array(v_card);
  END LOOP;

$new$);
  v_old := '  v_capacity := GREATEST(0, 13 - v_hand_count);';
  IF position(v_old IN v_def) = 0 THEN RAISE EXCEPTION 'Could not locate bot collection capacity.'; END IF;
  v_def := replace(v_def, v_old, '  v_capacity := 2147483647;');
  EXECUTE v_def;

  -- Human Sakura Leaf: allow collecting every opponent's selected card.
  SELECT pg_get_functiondef('public.play_sakura_leaf(uuid,text,jsonb)'::regprocedure) INTO v_def;
  v_old := $old$  IF jsonb_array_length(v_new_hand)>12 THEN
    RAISE EXCEPTION 'Sakura Leaf would exceed your 12-card hand limit.';
  END IF;

$old$;
  IF position(v_old IN v_def) = 0 THEN RAISE EXCEPTION 'Could not locate Sakura Leaf hand limit.'; END IF;
  v_def := replace(v_def, v_old, '');
  EXECUTE v_def;

  -- Human Tengu: allow both selected cards regardless of current hand size.
  SELECT pg_get_functiondef('public.play_tengu(uuid,text,uuid,jsonb)'::regprocedure) INTO v_def;
  v_old := $old$  IF jsonb_array_length(v_hand)>12 THEN
    RAISE EXCEPTION 'Tengu would exceed your 12-card hand limit.';
  END IF;

$old$;
  IF position(v_old IN v_def) = 0 THEN RAISE EXCEPTION 'Could not locate Tengu hand limit.'; END IF;
  v_def := replace(v_def, v_old, '');
  EXECUTE v_def;
END;
$migration$;
