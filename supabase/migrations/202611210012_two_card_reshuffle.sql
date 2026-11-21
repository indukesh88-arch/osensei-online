-- Ōsensei Online: reshuffle the Open Pile when only two non-Nure-Onna cards
-- remain in the Draw Deck, before the next player's draw.
-- Nure-Onna is normally placed at the bottom of the Draw Deck, but it joins
-- the shuffled deck like every other card when a reshuffle happens.

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
  v_non_nure_count integer;
  v_reshuffled boolean := false;
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

  -- Count the remaining cards other than Nure-Onna. Nure-Onna is placed at
  -- the bottom after being played, so it must not delay the two-card trigger.
  SELECT count(*)::integer
    INTO v_non_nure_count
  FROM jsonb_array_elements(v_deck) AS e(value)
  WHERE value->>'id' <> 'nure_onna';

  -- Before this player's draw, shuffle the entire Open Pile together with
  -- the remaining Draw Deck once only two non-Nure-Onna cards remain.
  IF v_non_nure_count <= 2 AND jsonb_array_length(v_open_pile) > 0 THEN
    SELECT COALESCE(
      jsonb_agg(value ORDER BY random()),
      '[]'::jsonb
    )
    INTO v_deck
    FROM jsonb_array_elements(v_deck || v_open_pile) AS e(value);

    v_open_pile := '[]'::jsonb;
    v_reshuffled := true;
  END IF;

  -- A full hand skips the draw, but the reshuffle above still happens before
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

  v_draw_count := CASE
    WHEN jsonb_array_length(v_hand) = 0 THEN 3
    WHEN jsonb_array_length(v_hand) = 1 THEN 2
    ELSE 1
  END;
  v_draw_count := LEAST(v_draw_count, 12 - jsonb_array_length(v_hand));

  -- If the Open Pile is not empty, do not draw past the two-card threshold.
  -- This leaves those two cards in the deck for the next-turn reshuffle.
  IF NOT v_reshuffled AND jsonb_array_length(v_open_pile) > 0
     AND v_non_nure_count > 2 THEN
    v_draw_count := LEAST(v_draw_count, v_non_nure_count - 2);
  END IF;

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
    SET draw_deck = v_deck,
        open_pile = v_open_pile,
        updated_at = now()
  WHERE room_id = p_room_id;

  RETURN jsonb_build_object(
    'success', true,
    'cards_in_hand', jsonb_array_length(v_hand),
    'cards_drawn', v_drawn,
    'cards_remaining', jsonb_array_length(v_deck),
    'reshuffled', v_reshuffled
  );
END;
$function$;
