-- Allow Sensei, Nure-Onna and defence specials to be played as ordinary cards.
-- Their special effects remain available through the separate attack/defence windows.

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
  v_deck jsonb;
  v_pile jsonb;
  v_card jsonb;
  v_next_seat integer;
  v_wrapped boolean:=false;
BEGIN
  IF p_card_id NOT IN (
    'sensei_man','sensei_woman','nure_onna',
    'silkworm_shield','tsubaki_flower','bonsai'
  ) THEN
    RAISE EXCEPTION 'This special card cannot be played as a normal card.';
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

  IF EXISTS(SELECT 1 FROM public.game_pending_attacks WHERE room_id=p_room_id) THEN
    RAISE EXCEPTION 'Resolve the pending elimination attack before playing a normal card.';
  END IF;

  SELECT cards INTO v_hand
  FROM public.player_hands
  WHERE room_id=p_room_id AND room_player_id=v_actor.id
  FOR UPDATE;
  v_hand:=COALESCE(v_hand,'[]'::jsonb);

  SELECT value INTO v_card
  FROM jsonb_array_elements(v_hand) AS e(value)
  WHERE value->>'id'=p_card_id
  LIMIT 1;
  IF v_card IS NULL THEN RAISE EXCEPTION 'That special card is not in your hand.'; END IF;

  SELECT COALESCE(jsonb_agg(value ORDER BY ordinality),'[]'::jsonb)
  INTO v_new_hand
  FROM jsonb_array_elements(v_hand) WITH ORDINALITY e(value,ordinality)
  WHERE value->>'id'<>p_card_id;

  v_deck:=COALESCE(v_state.draw_deck,'[]'::jsonb);
  v_pile:=COALESCE(v_state.open_pile,'[]'::jsonb);

  -- Nure-Onna always returns to the bottom of the Draw Deck after being played.
  IF p_card_id='nure_onna' THEN
    v_deck:=v_deck||jsonb_build_array(v_card);
  ELSE
    v_pile:=v_pile||jsonb_build_array(v_card);
  END IF;

  SELECT rp.seat_number INTO v_next_seat
  FROM public.room_players rp
  LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
  WHERE rp.room_id=p_room_id AND rp.turn_order>v_actor.turn_order
    AND COALESCE(gps.is_eliminated,false)=false
  ORDER BY rp.turn_order
  LIMIT 1;

  IF v_next_seat IS NULL THEN
    SELECT rp.seat_number INTO v_next_seat
    FROM public.room_players rp
    LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
    WHERE rp.room_id=p_room_id
      AND COALESCE(gps.is_eliminated,false)=false
    ORDER BY rp.turn_order
    LIMIT 1;
    v_wrapped:=true;
  END IF;
  IF v_next_seat IS NULL THEN RAISE EXCEPTION 'No active player remains.'; END IF;

  UPDATE public.player_hands
  SET cards=v_new_hand,updated_at=now()
  WHERE room_id=p_room_id AND room_player_id=v_actor.id;

  UPDATE public.game_states
  SET draw_deck=v_deck,
      open_pile=v_pile,
      current_turn_seat=v_next_seat,
      turn_number=v_state.turn_number+1,
      current_round=v_state.current_round+CASE WHEN v_wrapped THEN 1 ELSE 0 END,
      updated_at=now()
  WHERE room_id=p_room_id;

  RETURN jsonb_build_object(
    'success',true,
    'played_card',COALESCE(v_card->>'name',p_card_id),
    'next_seat',v_next_seat
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.play_special_card(uuid,text) TO authenticated;

-- Nure-Onna normal plays change the Draw Deck but not the Open Pile. Do not
-- mistake the previous Open Pile top card for a newly played card animation.
CREATE OR REPLACE FUNCTION public.record_card_animation_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_actor_id uuid;
  v_actor_name text;
  v_old_pile jsonb:=COALESCE(OLD.open_pile,'[]'::jsonb);
  v_new_pile jsonb:=COALESCE(NEW.open_pile,'[]'::jsonb);
  v_old_count integer;
  v_new_count integer;
  v_i integer;
  v_j integer;
  v_found boolean;
  v_played_card jsonb;
  v_collected_cards jsonb:='[]'::jsonb;
BEGIN
  IF NEW.turn_number IS NOT DISTINCT FROM OLD.turn_number THEN
    RETURN NEW;
  END IF;

  IF v_old_pile IS NOT DISTINCT FROM v_new_pile THEN
    RETURN NEW;
  END IF;

  SELECT rp.id,rp.player_name INTO v_actor_id,v_actor_name
  FROM public.room_players rp
  WHERE rp.room_id=NEW.room_id AND rp.seat_number=OLD.current_turn_seat
  ORDER BY rp.is_bot
  LIMIT 1;

  IF v_actor_id IS NULL THEN RETURN NEW; END IF;

  v_old_count:=jsonb_array_length(v_old_pile);
  v_new_count:=jsonb_array_length(v_new_pile);

  IF v_new_count>0 THEN
    v_played_card:=v_new_pile->(v_new_count-1);
    IF v_old_count>0 THEN
      FOR v_i IN 0..(v_old_count-1) LOOP
        v_found:=false;
        FOR v_j IN 0..(v_new_count-1) LOOP
          IF (v_old_pile->v_i)=(v_new_pile->v_j) THEN
            v_found:=true;
            EXIT;
          END IF;
        END LOOP;
        IF NOT v_found THEN
          v_collected_cards:=v_collected_cards||jsonb_build_array(v_old_pile->v_i);
        END IF;
      END LOOP;
    END IF;
  ELSE
    v_played_card:=jsonb_build_object('id','typhoon','name','Typhoon','category','weather');
    IF v_old_count>0 THEN
      FOR v_i IN GREATEST(0,v_old_count-2)..(v_old_count-1) LOOP
        v_collected_cards:=v_collected_cards||jsonb_build_array(v_old_pile->v_i);
      END LOOP;
    END IF;
  END IF;

  INSERT INTO public.game_animation_events(
    room_id,actor_player_id,recipient_player_id,actor_name,played_card,collected_cards
  )
  VALUES(
    NEW.room_id,v_actor_id,v_actor_id,COALESCE(v_actor_name,'A player'),
    v_played_card,v_collected_cards
  );

  RETURN NEW;
END;
$function$;
