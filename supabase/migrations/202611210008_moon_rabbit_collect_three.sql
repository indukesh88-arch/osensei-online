-- Moon Rabbit collects up to the top three cards from the Open/Play Pile.
-- Moon Rabbit itself is then placed on top of the remaining pile.

CREATE OR REPLACE FUNCTION public.play_moon_rabbit(
  p_room_id uuid,
  p_card_id text
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
  v_new_hand jsonb;
  v_collected jsonb := '[]'::jsonb;
  v_new_pile jsonb;
  v_collect_count integer := 0;
  v_wrapped boolean := false;
  v_index bigint;
BEGIN
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

  SELECT ordinality, value
  INTO v_index, v_card
  FROM jsonb_array_elements(v_hand)
    WITH ORDINALITY AS e(value, ordinality)
  WHERE value->>'id' = p_card_id
  LIMIT 1;

  IF v_card IS NULL THEN
    RAISE EXCEPTION 'That card is not in your hand.';
  END IF;

  IF v_card->>'id' <> 'moon_rabbit' THEN
    RAISE EXCEPTION 'That is not the Moon Rabbit card.';
  END IF;

  -- Collect up to three cards from the top of the pile. The final array
  -- element is the top card, so preserve the existing bottom-to-top order.
  v_collect_count := LEAST(3, jsonb_array_length(v_pile));

  IF v_collect_count > 0 THEN
    SELECT COALESCE(
      jsonb_agg(value ORDER BY ordinality),
      '[]'::jsonb
    )
    INTO v_collected
    FROM jsonb_array_elements(v_pile)
      WITH ORDINALITY AS e(value, ordinality)
    WHERE ordinality > jsonb_array_length(v_pile) - v_collect_count;

    SELECT COALESCE(
      jsonb_agg(value ORDER BY ordinality),
      '[]'::jsonb
    )
    INTO v_new_pile
    FROM jsonb_array_elements(v_pile)
      WITH ORDINALITY AS e(value, ordinality)
    WHERE ordinality <= jsonb_array_length(v_pile) - v_collect_count;

    v_pile := v_new_pile;
  END IF;

  SELECT COALESCE(
    jsonb_agg(value ORDER BY ordinality),
    '[]'::jsonb
  )
  INTO v_new_hand
  FROM jsonb_array_elements(v_hand)
    WITH ORDINALITY AS e(value, ordinality)
  WHERE ordinality <> v_index;

  v_new_hand := v_new_hand || v_collected;

  -- Moon Rabbit remains in the Play Pile as its new top card.
  v_pile := v_pile || jsonb_build_array(v_card);

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
  SET open_pile = v_pile,
      current_turn_seat = v_next_seat,
      turn_number = v_turn + 1,
      current_round = v_round + CASE WHEN v_wrapped THEN 1 ELSE 0 END,
      updated_at = now()
  WHERE room_id = p_room_id;

  RETURN jsonb_build_object(
    'success', true,
    'played_card', v_card->>'name',
    'cards_collected', v_collect_count,
    'next_seat', v_next_seat
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.play_moon_rabbit(uuid, text) TO authenticated;
