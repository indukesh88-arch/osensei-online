-- Remove the 12-card hand limit by replacing the affected RPC functions directly.
-- No pg_get_functiondef text matching is used.

CREATE OR REPLACE FUNCTION public.draw_game_card(p_room_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_player_id uuid;
  v_player_seat integer;
  v_turn_seat integer;
  v_turn_number integer;
  v_deck jsonb;
  v_open_pile jsonb;
  v_hand jsonb;
  v_last_draw integer;
  v_draw_count integer;
  v_drawn integer := 0;
  v_card jsonb;
BEGIN
  SELECT id, seat_number
    INTO v_player_id, v_player_seat
  FROM public.room_players
  WHERE room_id = p_room_id
    AND user_id = auth.uid()
    AND NOT is_bot;

  IF v_player_id IS NULL THEN
    RAISE EXCEPTION 'You are not a player in this room.';
  END IF;

  SELECT current_turn_seat, turn_number, draw_deck, open_pile
    INTO v_turn_seat, v_turn_number, v_deck, v_open_pile
  FROM public.game_states
  WHERE room_id = p_room_id AND status = 'playing'
  FOR UPDATE;

  IF v_turn_seat IS NULL OR v_turn_seat <> v_player_seat THEN
    RAISE EXCEPTION 'It is not your turn.';
  END IF;

  SELECT cards, last_draw_turn_number
    INTO v_hand, v_last_draw
  FROM public.player_hands
  WHERE room_id = p_room_id AND room_player_id = v_player_id
  FOR UPDATE;

  v_hand := COALESCE(v_hand, '[]'::jsonb);
  v_deck := COALESCE(v_deck, '[]'::jsonb);
  v_open_pile := COALESCE(v_open_pile, '[]'::jsonb);

  -- Idempotent: polling clients may request the same turn more than once.
  IF v_last_draw = v_turn_number THEN
    RETURN jsonb_build_object(
      'success', true,
      'already_processed', true,
      'cards_in_hand', jsonb_array_length(v_hand),
      'cards_drawn', 0,
      'cards_remaining', jsonb_array_length(v_deck)
    );
  END IF;

  -- Rulebook: if exactly three cards remain and the open pile is empty,
  -- drawing pauses for the exhaustion sequence.
  IF jsonb_array_length(v_deck) = 3 AND jsonb_array_length(v_open_pile) = 0 THEN
    UPDATE public.player_hands
      SET last_draw_turn_number = v_turn_number, updated_at = now()
    WHERE room_id = p_room_id AND room_player_id = v_player_id;

    RETURN jsonb_build_object(
      'success', true, 'draw_paused', true,
      'cards_in_hand', jsonb_array_length(v_hand),
      'cards_drawn', 0, 'cards_remaining', jsonb_array_length(v_deck)
    );
  END IF;

  v_draw_count := CASE
    WHEN jsonb_array_length(v_hand) = 0 THEN 3
    WHEN jsonb_array_length(v_hand) = 1 THEN 2
    ELSE 1
  END;

  WHILE v_drawn < v_draw_count AND jsonb_array_length(v_deck) > 0 LOOP
    v_card := v_deck -> 0;
    v_hand := v_hand || jsonb_build_array(v_card);
    v_deck := v_deck - 0;
    v_drawn := v_drawn + 1;
  END LOOP;

  UPDATE public.player_hands
    SET cards = v_hand,
        last_draw_turn_number = v_turn_number,
        updated_at = now()
  WHERE room_id = p_room_id AND room_player_id = v_player_id;

  UPDATE public.game_states
    SET draw_deck = v_deck, updated_at = now()
  WHERE room_id = p_room_id;

  RETURN jsonb_build_object(
    'success', true,
    'cards_in_hand', jsonb_array_length(v_hand),
    'cards_drawn', v_drawn,
    'cards_remaining', jsonb_array_length(v_deck)
  );
END;
$function$;
