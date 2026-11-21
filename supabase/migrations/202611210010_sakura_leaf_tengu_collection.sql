-- Sakura Leaf: choose one hidden card from each active opponent in sequence.
-- Tengu: choose one active opponent, then choose two hidden cards from that hand.
-- Both played special cards remain on top of the Open/Play Pile.

CREATE OR REPLACE FUNCTION public.get_collect_opponents(p_room_id uuid)
RETURNS TABLE(player_id uuid, player_name text, turn_order integer, hand_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_actor_id uuid;
  v_turn_seat integer;
BEGIN
  SELECT current_turn_seat INTO v_turn_seat
  FROM public.game_states
  WHERE room_id=p_room_id AND status='playing';

  SELECT id INTO v_actor_id
  FROM public.room_players
  WHERE room_id=p_room_id AND user_id=auth.uid()
    AND seat_number=v_turn_seat AND NOT is_bot;

  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'It is not your turn.';
  END IF;

  RETURN QUERY
  SELECT rp.id, rp.player_name, rp.turn_order,
         jsonb_array_length(COALESCE(ph.cards,'[]'::jsonb))::integer
  FROM public.room_players rp
  LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
  LEFT JOIN public.player_hands ph ON ph.room_id=p_room_id AND ph.room_player_id=rp.id
  WHERE rp.room_id=p_room_id AND rp.id<>v_actor_id
    AND COALESCE(gps.is_eliminated,false)=false
  ORDER BY rp.turn_order;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_collect_opponents(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.play_sakura_leaf(
  p_room_id uuid,
  p_card_id text,
  p_selections jsonb
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
  v_target record;
  v_target_hand jsonb;
  v_target_new_hand jsonb;
  v_selected jsonb;
  v_collected_cards jsonb:='[]'::jsonb;
  v_selection jsonb;
  v_target_ids uuid[];
  v_seen_ids uuid[] := ARRAY[]::uuid[];
  v_target_id uuid;
  v_index integer;
  v_count integer;
  v_order integer;
  v_next_seat integer;
  v_round integer;
  v_wrapped boolean := false;
BEGIN
  IF p_card_id IS DISTINCT FROM 'sakura_leaf' OR COALESCE(jsonb_typeof(p_selections),'')<>'array' THEN
    RAISE EXCEPTION 'Invalid Sakura Leaf selection.';
  END IF;

  SELECT * INTO v_state
  FROM public.game_states
  WHERE room_id=p_room_id AND status='playing'
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Game is not active.'; END IF;

  SELECT * INTO v_actor
  FROM public.room_players
  WHERE room_id=p_room_id AND user_id=auth.uid()
    AND seat_number=v_state.current_turn_seat AND NOT is_bot;
  IF NOT FOUND THEN RAISE EXCEPTION 'It is not your turn.'; END IF;

  SELECT cards INTO v_hand
  FROM public.player_hands
  WHERE room_id=p_room_id AND room_player_id=v_actor.id
  FOR UPDATE;
  v_hand:=COALESCE(v_hand,'[]'::jsonb);
  v_pile:=COALESCE(v_state.open_pile,'[]'::jsonb);

  SELECT value INTO v_card
  FROM jsonb_array_elements(v_hand) AS e(value)
  WHERE value->>'id'='sakura_leaf' LIMIT 1;
  IF v_card IS NULL THEN RAISE EXCEPTION 'Sakura Leaf is not in your hand.'; END IF;

  SELECT COALESCE(array_agg(rp.id ORDER BY rp.turn_order),ARRAY[]::uuid[])
  INTO v_target_ids
  FROM public.room_players rp
  LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
  WHERE rp.room_id=p_room_id AND rp.id<>v_actor.id
    AND COALESCE(gps.is_eliminated,false)=false;

  IF jsonb_array_length(p_selections)<>COALESCE(array_length(v_target_ids,1),0) THEN
    RAISE EXCEPTION 'Choose exactly one hidden card from every active opponent.';
  END IF;

  SELECT COALESCE(jsonb_agg(value ORDER BY ordinality),'[]'::jsonb)
  INTO v_new_hand
  FROM jsonb_array_elements(v_hand) WITH ORDINALITY e(value,ordinality)
  WHERE value->>'id'<>'sakura_leaf';

  FOR v_selection IN SELECT value FROM jsonb_array_elements(p_selections) LOOP
    v_target_id:=(v_selection->>'target_player_id')::uuid;
    v_index:=(v_selection->>'card_index')::integer;
    IF v_target_id IS NULL THEN RAISE EXCEPTION 'Invalid opponent selection.'; END IF;
    IF v_target_id=ANY(v_seen_ids) THEN
      RAISE EXCEPTION 'Each opponent can be selected only once.';
    END IF;
    v_seen_ids:=array_append(v_seen_ids,v_target_id);
    IF NOT (v_target_id=ANY(v_target_ids)) OR (v_index IS NOT NULL AND v_index<0) THEN
      RAISE EXCEPTION 'Invalid opponent or hidden-card selection.';
    END IF;

    SELECT cards INTO v_target_hand
    FROM public.player_hands
    WHERE room_id=p_room_id AND room_player_id=v_target_id
    FOR UPDATE;
    v_target_hand:=COALESCE(v_target_hand,'[]'::jsonb);

    IF v_index IS NULL THEN
      IF jsonb_array_length(v_target_hand)>0 THEN
        RAISE EXCEPTION 'An opponent hand changed. Please make your selections again.';
      END IF;
      v_target_new_hand:=v_target_hand;
    ELSE
      IF v_index>=jsonb_array_length(v_target_hand) THEN
        RAISE EXCEPTION 'An opponent hand changed. Please make your selections again.';
      END IF;
      SELECT value INTO v_selected
      FROM jsonb_array_elements(v_target_hand) WITH ORDINALITY e(value,ordinality)
      WHERE ordinality=v_index+1;
      v_new_hand:=v_new_hand||jsonb_build_array(v_selected);
      v_collected_cards:=v_collected_cards||jsonb_build_array(v_selected);

      SELECT COALESCE(jsonb_agg(value ORDER BY ordinality),'[]'::jsonb)
      INTO v_target_new_hand
      FROM jsonb_array_elements(v_target_hand) WITH ORDINALITY e(value,ordinality)
      WHERE ordinality<>v_index+1;
    END IF;

    UPDATE public.player_hands SET cards=v_target_new_hand,updated_at=now()
    WHERE room_id=p_room_id AND room_player_id=v_target_id;
  END LOOP;

  IF jsonb_array_length(v_new_hand)>12 THEN
    RAISE EXCEPTION 'Sakura Leaf would exceed your 12-card hand limit.';
  END IF;

  v_pile:=v_pile||jsonb_build_array(v_card);
  SELECT rp.seat_number INTO v_next_seat
  FROM public.room_players rp
  LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
  WHERE rp.room_id=p_room_id AND rp.turn_order>v_actor.turn_order
    AND COALESCE(gps.is_eliminated,false)=false
  ORDER BY rp.turn_order LIMIT 1;
  IF v_next_seat IS NULL THEN
    SELECT rp.seat_number INTO v_next_seat
    FROM public.room_players rp
    LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
    WHERE rp.room_id=p_room_id AND COALESCE(gps.is_eliminated,false)=false
    ORDER BY rp.turn_order LIMIT 1;
    v_wrapped:=true;
  END IF;
  IF v_next_seat IS NULL THEN RAISE EXCEPTION 'No active player remains.'; END IF;

  UPDATE public.player_hands SET cards=v_new_hand,updated_at=now()
  WHERE room_id=p_room_id AND room_player_id=v_actor.id;
  UPDATE public.game_states SET open_pile=v_pile,current_turn_seat=v_next_seat,
    turn_number=v_state.turn_number+1,
    current_round=v_state.current_round+CASE WHEN v_wrapped THEN 1 ELSE 0 END,
    updated_at=now()
  WHERE room_id=p_room_id;

  UPDATE public.game_animation_events SET collected_cards=v_collected_cards,recipient_player_id=v_actor.id
  WHERE id=(SELECT id FROM public.game_animation_events WHERE room_id=p_room_id AND actor_player_id=v_actor.id ORDER BY id DESC LIMIT 1);

  RETURN jsonb_build_object('success',true,'played_card',v_card->>'name',
    'cards_collected',jsonb_array_length(v_collected_cards),'next_seat',v_next_seat);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.play_sakura_leaf(uuid,text,jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.play_tengu(
  p_room_id uuid,
  p_card_id text,
  p_target_player_id uuid,
  p_card_indices jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_state record;
  v_actor record;
  v_target record;
  v_hand jsonb;
  v_new_hand jsonb;
  v_target_hand jsonb;
  v_target_new_hand jsonb;
  v_pile jsonb;
  v_card jsonb;
  v_selected jsonb;
  v_collected_cards jsonb:='[]'::jsonb;
  v_index integer;
  v_indices integer[]:=ARRAY[]::integer[];
  v_next_seat integer;
  v_wrapped boolean:=false;
  v_expected_count integer;
BEGIN
  IF p_card_id IS DISTINCT FROM 'tengu' OR COALESCE(jsonb_typeof(p_card_indices),'')<>'array' THEN
    RAISE EXCEPTION 'Invalid Tengu selection.';
  END IF;
  IF jsonb_array_length(p_card_indices)>2 THEN
    RAISE EXCEPTION 'Choose up to two hidden cards.';
  END IF;

  SELECT * INTO v_state FROM public.game_states
  WHERE room_id=p_room_id AND status='playing' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Game is not active.'; END IF;

  SELECT * INTO v_actor FROM public.room_players
  WHERE room_id=p_room_id AND user_id=auth.uid()
    AND seat_number=v_state.current_turn_seat AND NOT is_bot;
  IF NOT FOUND THEN RAISE EXCEPTION 'It is not your turn.'; END IF;

  SELECT * INTO v_target
  FROM public.room_players rp
  LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
  WHERE rp.room_id=p_room_id AND rp.id=p_target_player_id
    AND rp.id<>v_actor.id AND COALESCE(gps.is_eliminated,false)=false;
  IF NOT FOUND THEN RAISE EXCEPTION 'Choose an active opponent.'; END IF;

  SELECT cards INTO v_hand FROM public.player_hands
  WHERE room_id=p_room_id AND room_player_id=v_actor.id FOR UPDATE;
  v_hand:=COALESCE(v_hand,'[]'::jsonb);
  SELECT value INTO v_card FROM jsonb_array_elements(v_hand) e(value)
  WHERE value->>'id'='tengu' LIMIT 1;
  IF v_card IS NULL THEN RAISE EXCEPTION 'Tengu is not in your hand.'; END IF;

  SELECT cards INTO v_target_hand FROM public.player_hands
  WHERE room_id=p_room_id AND room_player_id=v_target.id FOR UPDATE;
  v_target_hand:=COALESCE(v_target_hand,'[]'::jsonb);
  v_expected_count:=LEAST(2,jsonb_array_length(v_target_hand));
  IF jsonb_array_length(p_card_indices)<>v_expected_count THEN
    RAISE EXCEPTION 'Select % hidden card(s) from this opponent.',v_expected_count;
  END IF;

  FOR v_index IN SELECT (value::text)::integer FROM jsonb_array_elements(p_card_indices) LOOP
    IF v_index<0 OR v_index>=jsonb_array_length(v_target_hand) OR v_index=ANY(v_indices) THEN
      RAISE EXCEPTION 'Invalid or repeated hidden-card selection.';
    END IF;
    v_indices:=array_append(v_indices,v_index);
    SELECT value INTO v_selected FROM jsonb_array_elements(v_target_hand)
      WITH ORDINALITY e(value,ordinality) WHERE ordinality=v_index+1;
    v_new_hand:=COALESCE(v_new_hand,'[]'::jsonb)||jsonb_build_array(v_selected);
    v_collected_cards:=v_collected_cards||jsonb_build_array(v_selected);
  END LOOP;

  SELECT COALESCE(jsonb_agg(value ORDER BY ordinality),'[]'::jsonb)
  INTO v_target_new_hand
  FROM jsonb_array_elements(v_target_hand) WITH ORDINALITY e(value,ordinality)
  WHERE NOT ((ordinality-1)::integer=ANY(v_indices));

  SELECT COALESCE(jsonb_agg(value ORDER BY ordinality),'[]'::jsonb)
  INTO v_hand
  FROM jsonb_array_elements(v_hand) WITH ORDINALITY e(value,ordinality)
  WHERE value->>'id'<>'tengu';
  v_hand:=v_hand||COALESCE(v_new_hand,'[]'::jsonb);
  IF jsonb_array_length(v_hand)>12 THEN
    RAISE EXCEPTION 'Tengu would exceed your 12-card hand limit.';
  END IF;

  v_pile:=COALESCE(v_state.open_pile,'[]'::jsonb)||jsonb_build_array(v_card);
  SELECT rp.seat_number INTO v_next_seat
  FROM public.room_players rp
  LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
  WHERE rp.room_id=p_room_id AND rp.turn_order>v_actor.turn_order
    AND COALESCE(gps.is_eliminated,false)=false
  ORDER BY rp.turn_order LIMIT 1;
  IF v_next_seat IS NULL THEN
    SELECT rp.seat_number INTO v_next_seat
    FROM public.room_players rp
    LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
    WHERE rp.room_id=p_room_id AND COALESCE(gps.is_eliminated,false)=false
    ORDER BY rp.turn_order LIMIT 1;
    v_wrapped:=true;
  END IF;
  IF v_next_seat IS NULL THEN RAISE EXCEPTION 'No active player remains.'; END IF;

  UPDATE public.player_hands SET cards=v_target_new_hand,updated_at=now()
  WHERE room_id=p_room_id AND room_player_id=v_target.id;
  UPDATE public.player_hands SET cards=v_hand,updated_at=now()
  WHERE room_id=p_room_id AND room_player_id=v_actor.id;
  UPDATE public.game_states SET open_pile=v_pile,current_turn_seat=v_next_seat,
    turn_number=v_state.turn_number+1,
    current_round=v_state.current_round+CASE WHEN v_wrapped THEN 1 ELSE 0 END,
    updated_at=now()
  WHERE room_id=p_room_id;

  UPDATE public.game_animation_events SET collected_cards=v_collected_cards,recipient_player_id=v_actor.id
  WHERE id=(SELECT id FROM public.game_animation_events WHERE room_id=p_room_id AND actor_player_id=v_actor.id ORDER BY id DESC LIMIT 1);

  RETURN jsonb_build_object('success',true,'played_card',v_card->>'name',
    'cards_collected',jsonb_array_length(v_collected_cards),'next_seat',v_next_seat);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.play_tengu(uuid,text,uuid,jsonb) TO authenticated;
