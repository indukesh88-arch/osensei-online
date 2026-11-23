-- Ensure attack/defence special cards can be discarded as ordinary cards.
-- Collection cards (Tengu, Sakura Leaf, Kappa and Moon Rabbit) are deliberately
-- excluded and continue to use their dedicated ability RPCs.
-- Every ordinary special-card play goes to the Open Pile, including Nure-Onna.

CREATE OR REPLACE FUNCTION public.play_special_card(
  p_room_id uuid,
  p_card_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_state record;
  v_actor record;
  v_hand jsonb;
  v_new_hand jsonb;
  v_pile jsonb;
  v_card jsonb;
  v_next_seat integer;
  v_wrapped boolean := false;
BEGIN
  IF p_card_id NOT IN (
    'sensei_man',
    'sensei_woman',
    'nure_onna',
    'silkworm_shield',
    'tsubaki_flower',
    'bonsai'
  ) THEN
    RAISE EXCEPTION 'This special card cannot be played as a normal card.';
  END IF;

  SELECT *
  INTO v_state
  FROM public.game_states
  WHERE room_id = p_room_id
    AND status = 'playing'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Game is not active.';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.room_players
  WHERE room_id = p_room_id
    AND user_id = auth.uid()
    AND seat_number = v_state.current_turn_seat
    AND NOT is_bot;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'It is not your turn.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.game_pending_attacks
    WHERE room_id = p_room_id
  ) THEN
    RAISE EXCEPTION 'Resolve the pending elimination attack before playing a normal card.';
  END IF;

  SELECT cards
  INTO v_hand
  FROM public.player_hands
  WHERE room_id = p_room_id
    AND room_player_id = v_actor.id
  FOR UPDATE;

  v_hand := COALESCE(v_hand, '[]'::jsonb);

  SELECT value
  INTO v_card
  FROM jsonb_array_elements(v_hand) AS e(value)
  WHERE value->>'id' = p_card_id
  LIMIT 1;

  IF v_card IS NULL THEN
    RAISE EXCEPTION 'That special card is not in your hand.';
  END IF;

  SELECT COALESCE(jsonb_agg(value ORDER BY ordinality), '[]'::jsonb)
  INTO v_new_hand
  FROM jsonb_array_elements(v_hand) WITH ORDINALITY AS e(value, ordinality)
  WHERE value->>'id' <> p_card_id;

  v_pile := COALESCE(v_state.open_pile, '[]'::jsonb)
            || jsonb_build_array(v_card);

  SELECT rp.seat_number
  INTO v_next_seat
  FROM public.room_players rp
  LEFT JOIN public.game_player_states gps
    ON gps.room_player_id = rp.id
  WHERE rp.room_id = p_room_id
    AND rp.turn_order > v_actor.turn_order
    AND COALESCE(gps.is_eliminated, false) = false
  ORDER BY rp.turn_order
  LIMIT 1;

  IF v_next_seat IS NULL THEN
    SELECT rp.seat_number
    INTO v_next_seat
    FROM public.room_players rp
    LEFT JOIN public.game_player_states gps
      ON gps.room_player_id = rp.id
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
    AND room_player_id = v_actor.id;

  UPDATE public.game_states
  SET open_pile = v_pile,
      current_turn_seat = v_next_seat,
      turn_number = v_state.turn_number + 1,
      current_round = v_state.current_round
        + CASE WHEN v_wrapped THEN 1 ELSE 0 END,
      updated_at = now()
  WHERE room_id = p_room_id;

  RETURN jsonb_build_object(
    'success', true,
    'played_card', COALESCE(v_card->>'name', p_card_id),
    'cards_collected', 0,
    'next_seat', v_next_seat
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.play_special_card(uuid, text)
TO authenticated;

NOTIFY pgrst, 'reload schema';
