-- Kappa collects exactly one card chosen by the player from anywhere in the Open Pile.
-- The chosen card is removed from its current position; Kappa is placed on top.

CREATE OR REPLACE FUNCTION public.play_kappa(
  p_room_id uuid,
  p_card_id text,
  p_pile_index integer,
  p_selected_card jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_player_id uuid;
  v_seat integer;
  v_order integer;
  v_turn_seat integer;
  v_round integer;
  v_turn integer;
  v_next_seat integer;
  v_next_order integer;
  v_hand jsonb;
  v_pile jsonb;
  v_card jsonb;
  v_collected jsonb;
  v_new_hand jsonb;
  v_new_pile jsonb;
  v_wrapped boolean := false;
BEGIN
  IF p_pile_index IS NULL OR p_pile_index < 0 THEN
    RAISE EXCEPTION 'Choose a valid card from the Open Pile.';
  END IF;

  SELECT id, seat_number, turn_order
  INTO v_player_id, v_seat, v_order
  FROM public.room_players
  WHERE room_id = p_room_id
    AND user_id = auth.uid()
    AND is_bot = false;

  IF v_player_id IS NULL THEN
    RAISE EXCEPTION 'You are not a human player in this room.';
  END IF;

  SELECT current_turn_seat, current_round, turn_number, open_pile
  INTO v_turn_seat, v_round, v_turn, v_pile
  FROM public.game_states
  WHERE room_id = p_room_id
    AND status = 'playing'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Game is not active.';
  END IF;

  IF v_turn_seat IS DISTINCT FROM v_seat THEN
    RAISE EXCEPTION 'It is not your turn.';
  END IF;

  SELECT cards
  INTO v_hand
  FROM public.player_hands
  WHERE room_id = p_room_id
    AND room_player_id = v_player_id
  FOR UPDATE;

  v_hand := COALESCE(v_hand, '[]'::jsonb);
  v_pile := COALESCE(v_pile, '[]'::jsonb);

  IF p_card_id <> 'kappa' THEN
    RAISE EXCEPTION 'That is not the Kappa card.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(v_hand) AS e(value)
    WHERE value->>'id' = 'kappa'
  ) THEN
    RAISE EXCEPTION 'Kappa is not in your hand.';
  END IF;

  IF p_pile_index >= jsonb_array_length(v_pile) THEN
    RAISE EXCEPTION 'That Open Pile selection is no longer available. Please choose again.';
  END IF;

  SELECT value
  INTO v_collected
  FROM jsonb_array_elements(v_pile)
    WITH ORDINALITY AS e(value, ordinality)
  WHERE ordinality = p_pile_index + 1;

  IF p_selected_card IS NULL OR v_collected IS DISTINCT FROM p_selected_card THEN
    RAISE EXCEPTION 'The selected card changed. Please select it again.';
  END IF;

  SELECT value
  INTO v_card
  FROM jsonb_array_elements(v_hand) AS e(value)
  WHERE value->>'id' = 'kappa'
  LIMIT 1;

  SELECT COALESCE(jsonb_agg(value ORDER BY ordinality), '[]'::jsonb)
  INTO v_new_pile
  FROM jsonb_array_elements(v_pile)
    WITH ORDINALITY AS e(value, ordinality)
  WHERE ordinality <> p_pile_index + 1;

  SELECT COALESCE(jsonb_agg(value ORDER BY ordinality), '[]'::jsonb)
  INTO v_new_hand
  FROM jsonb_array_elements(v_hand)
    WITH ORDINALITY AS e(value, ordinality)
  WHERE value->>'id' <> 'kappa';

  v_new_hand := v_new_hand || jsonb_build_array(v_collected);

  -- Kappa itself remains in the Open Pile as the newest/top card.
  v_new_pile := v_new_pile || jsonb_build_array(v_card);

  SELECT rp.seat_number, rp.turn_order
  INTO v_next_seat, v_next_order
  FROM public.room_players rp
  LEFT JOIN public.game_player_states gps ON gps.room_player_id = rp.id
  WHERE rp.room_id = p_room_id
    AND rp.turn_order > v_order
    AND COALESCE(gps.is_eliminated, false) = false
  ORDER BY rp.turn_order
  LIMIT 1;

  IF NOT FOUND THEN
    SELECT rp.seat_number, rp.turn_order
    INTO v_next_seat, v_next_order
    FROM public.room_players rp
    LEFT JOIN public.game_player_states gps ON gps.room_player_id = rp.id
    WHERE rp.room_id = p_room_id
      AND COALESCE(gps.is_eliminated, false) = false
    ORDER BY rp.turn_order
    LIMIT 1;

    v_wrapped := true;
  END IF;

  IF v_next_seat IS NULL THEN
    RAISE EXCEPTION 'No active player remains.';
  END IF;

  UPDATE public.player_hands
  SET cards = v_new_hand,
      updated_at = now()
  WHERE room_id = p_room_id
    AND room_player_id = v_player_id;

  UPDATE public.game_states
  SET open_pile = v_new_pile,
      current_turn_seat = v_next_seat,
      turn_number = v_turn + 1,
      current_round = v_round + CASE WHEN v_wrapped THEN 1 ELSE 0 END,
      updated_at = now()
  WHERE room_id = p_room_id;

  RETURN jsonb_build_object(
    'success', true,
    'played_card', v_card->>'name',
    'collected_card', v_collected->>'name',
    'next_seat', v_next_seat
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.play_kappa(uuid, text, integer) TO authenticated;
