-- Resolve or defend a pending elimination attack.
CREATE OR REPLACE FUNCTION public.respond_to_elimination(
  p_room_id uuid,
  p_action text,
  p_defence_card_ids text[] DEFAULT ARRAY[]::text[],
  p_collect_card_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_attack record;
  v_state record;
  v_defender record;
  v_attacker record;
  v_hand jsonb;
  v_new_hand jsonb := '[]'::jsonb;
  v_pile jsonb;
  v_deck jsonb;
  v_card jsonb;
  v_extra jsonb;
  v_points integer := 0;
  v_has_bonsai boolean := false;
  v_has_silkworm boolean := false;
  v_has_tsubaki boolean := false;
  v_has_extra boolean := false;
  v_next record;
  v_next_seat integer;
  v_next_order integer;
  v_wrapped boolean := false;
  v_eliminated boolean := false;
BEGIN
  SELECT * INTO v_attack FROM public.game_pending_attacks
  WHERE room_id=p_room_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'There is no pending elimination attack.'; END IF;

  SELECT * INTO v_state FROM public.game_states
  WHERE room_id=p_room_id AND status='playing' FOR UPDATE;
  SELECT * INTO v_defender FROM public.room_players
  WHERE id=v_attack.target_player_id AND room_id=p_room_id
    AND (
      (NOT is_bot AND user_id=auth.uid())
      OR
      (is_bot AND EXISTS (
        SELECT 1 FROM public.game_rooms gr
        WHERE gr.id=p_room_id AND gr.host_id=auth.uid()
      ))
    );
  IF NOT FOUND THEN RAISE EXCEPTION 'Only the targeted player can respond.'; END IF;

  SELECT * INTO v_attacker FROM public.room_players
  WHERE id=v_attack.attacker_player_id AND room_id=p_room_id;

  SELECT cards INTO v_hand FROM public.player_hands
  WHERE room_id=p_room_id AND room_player_id=v_defender.id FOR UPDATE;
  v_hand := COALESCE(v_hand,'[]'::jsonb);
  v_pile := COALESCE(v_state.open_pile,'[]'::jsonb);
  v_deck := COALESCE(v_state.draw_deck,'[]'::jsonb);

  IF p_action='accept' THEN
    v_eliminated := true;
  ELSIF p_action IN ('points','silkworm','tsubaki','bonsai') THEN
    IF COALESCE(array_length(p_defence_card_ids,1),0)=0 THEN
      RAISE EXCEPTION 'Select the defence card or cards to play.';
    END IF;
    IF (SELECT count(DISTINCT x) FROM unnest(p_defence_card_ids) x) <> array_length(p_defence_card_ids,1) THEN
      RAISE EXCEPTION 'A defence card can only be selected once.';
    END IF;

    FOR v_card IN SELECT value FROM jsonb_array_elements(v_hand)
      WHERE value->>'id'=ANY(p_defence_card_ids)
    LOOP
      IF v_card->>'category' IN ('season','weather') THEN
        v_points := v_points + COALESCE((v_card->>'points')::integer,(v_card->>'number')::integer,0);
      ELSIF v_card->>'id'='bonsai' THEN v_has_bonsai:=true;
      ELSIF v_card->>'id'='silkworm_shield' THEN v_has_silkworm:=true;
      ELSIF v_card->>'id'='tsubaki_flower' THEN v_has_tsubaki:=true;
      ELSE v_has_extra:=true;
      END IF;
    END LOOP;
    IF (SELECT count(*) FROM jsonb_array_elements(v_hand) WHERE value->>'id'=ANY(p_defence_card_ids))
       <> array_length(p_defence_card_ids,1) THEN
      RAISE EXCEPTION 'A selected defence card is not in your hand.';
    END IF;

    IF p_action='points' THEN
      IF v_attack.attack_kind IN ('nure_onna','nure_sensei') THEN
        RAISE EXCEPTION 'Points cannot defend against Nure-Onna.';
      END IF;
      IF v_points<21 OR v_has_bonsai OR v_has_silkworm OR v_has_tsubaki OR v_has_extra THEN
        RAISE EXCEPTION 'A points defence requires Season/Weather cards totaling at least 21.';
      END IF;
    ELSIF p_action='silkworm' THEN
      IF NOT v_has_silkworm OR array_length(p_defence_card_ids,1)<>1 THEN
        RAISE EXCEPTION 'Silkworm Shield must be played by itself.';
      END IF;
      IF p_collect_card_id IS NOT NULL AND NOT EXISTS(
        SELECT 1 FROM jsonb_array_elements(v_pile) WHERE value->>'id'=p_collect_card_id
      ) THEN RAISE EXCEPTION 'The chosen open-pile card is unavailable.'; END IF;
    ELSIF p_action='tsubaki' THEN
      IF v_attack.attack_kind IN ('nure_onna','nure_sensei') THEN
        RAISE EXCEPTION 'Tsubaki Flower cannot defend against Nure-Onna.';
      END IF;
      IF NOT v_has_tsubaki OR array_length(p_defence_card_ids,1)<>1 THEN
        RAISE EXCEPTION 'Tsubaki Flower must be played by itself.';
      END IF;
    ELSIF p_action='bonsai' THEN
      IF v_attack.attack_kind IN ('nure_onna','nure_sensei') THEN
        RAISE EXCEPTION 'Bonsai cannot defend against Nure-Onna.';
      END IF;
      IF NOT v_has_bonsai OR NOT (v_points>=7 OR v_has_extra) THEN
        RAISE EXCEPTION 'Bonsai requires Season/Weather points totaling 7 or one other special card.';
      END IF;
    END IF;

    -- Move defence cards to the open pile and remove them from the defender's hand.
    SELECT COALESCE(jsonb_agg(h.value ORDER BY h.ordinality),'[]'::jsonb)
    INTO v_new_hand
    FROM jsonb_array_elements(v_hand) WITH ORDINALITY h(value,ordinality)
    WHERE NOT (h.value->>'id'=ANY(p_defence_card_ids));
    SELECT COALESCE(jsonb_agg(value),'[]'::jsonb)
    INTO v_extra FROM jsonb_array_elements(v_hand)
    WHERE value->>'id'=ANY(p_defence_card_ids);
    v_pile := v_pile || COALESCE(v_extra,'[]'::jsonb);
    UPDATE public.player_hands SET cards=v_new_hand,updated_at=now()
    WHERE room_id=p_room_id AND room_player_id=v_defender.id;

    IF p_action='tsubaki' THEN
      SELECT rp.id,rp.seat_number,rp.turn_order INTO v_next
      FROM public.room_players rp
      LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
      WHERE rp.room_id=p_room_id AND rp.turn_order>v_defender.turn_order
        AND COALESCE(gps.is_eliminated,false)=false
      ORDER BY rp.turn_order LIMIT 1;
      IF NOT FOUND THEN
        SELECT rp.id,rp.seat_number,rp.turn_order INTO v_next
        FROM public.room_players rp
        LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
        WHERE rp.room_id=p_room_id AND COALESCE(gps.is_eliminated,false)=false
        ORDER BY rp.turn_order LIMIT 1;
      END IF;
      IF v_next.id IS NULL THEN RAISE EXCEPTION 'No active player can receive the redirected attack.'; END IF;
      UPDATE public.game_pending_attacks SET target_player_id=v_next.id WHERE room_id=p_room_id;
      UPDATE public.game_states SET open_pile=v_pile,updated_at=now() WHERE room_id=p_room_id;
      RETURN jsonb_build_object('success',true,'redirected',true,'target_player_id',v_next.id);
    END IF;

    IF p_action='silkworm' AND p_collect_card_id IS NOT NULL THEN
      SELECT COALESCE(jsonb_agg(value ORDER BY ordinality),'[]'::jsonb)
      INTO v_extra FROM jsonb_array_elements(v_pile) WITH ORDINALITY
      WHERE value->>'id'=p_collect_card_id;
      SELECT COALESCE(jsonb_agg(value ORDER BY ordinality),'[]'::jsonb)
      INTO v_pile FROM jsonb_array_elements(v_pile) WITH ORDINALITY
      WHERE value->>'id'<>p_collect_card_id;
      UPDATE public.player_hands SET cards=cards||v_extra,updated_at=now()
      WHERE room_id=p_room_id AND room_player_id=v_defender.id;
    END IF;

    UPDATE public.game_states SET open_pile=v_pile,updated_at=now() WHERE room_id=p_room_id;
    DELETE FROM public.game_pending_attacks WHERE room_id=p_room_id;
  ELSE
    RAISE EXCEPTION 'Unknown defence action.';
  END IF;

  IF v_eliminated THEN
    UPDATE public.game_player_states SET is_eliminated=true,
      eliminated_round=v_state.current_round,updated_at=now()
    WHERE room_id=p_room_id AND room_player_id=v_defender.id;
    UPDATE public.player_hands SET cards='[]'::jsonb,updated_at=now()
    WHERE room_id=p_room_id AND room_player_id=v_defender.id;
    UPDATE public.player_hands SET cards=COALESCE(cards,'[]'::jsonb)||v_hand,updated_at=now()
    WHERE room_id=p_room_id AND room_player_id=v_attacker.id;
    DELETE FROM public.game_pending_attacks WHERE room_id=p_room_id;
  END IF;

  -- The last surviving player wins immediately.
  IF (SELECT count(*) FROM public.room_players rp
      LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
      WHERE rp.room_id=p_room_id AND COALESCE(gps.is_eliminated,false)=false)=1 THEN
    UPDATE public.game_states SET status='finished',updated_at=now() WHERE room_id=p_room_id;
    UPDATE public.game_rooms SET status='finished' WHERE id=p_room_id;
    RETURN jsonb_build_object('success',true,'eliminated',v_eliminated,
      'defended',NOT v_eliminated,'game_over',true,'winner_player_id',v_attacker.id);
  END IF;

  -- Whether the target was eliminated or successfully defended, the turn
  -- passes to the first active seat clockwise from the original attacker.
  SELECT rp.seat_number,rp.turn_order INTO v_next_seat,v_next_order
  FROM public.room_players rp
  LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
  WHERE rp.room_id=p_room_id AND rp.turn_order>v_attacker.turn_order
    AND COALESCE(gps.is_eliminated,false)=false
  ORDER BY rp.turn_order LIMIT 1;
  IF NOT FOUND THEN
    SELECT rp.seat_number,rp.turn_order INTO v_next_seat,v_next_order
    FROM public.room_players rp
    LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
    WHERE rp.room_id=p_room_id AND COALESCE(gps.is_eliminated,false)=false
    ORDER BY rp.turn_order LIMIT 1;
    v_wrapped:=true;
  END IF;
  IF v_next_seat IS NULL THEN
    UPDATE public.game_states SET status='finished',updated_at=now() WHERE room_id=p_room_id;
    UPDATE public.game_rooms SET status='finished' WHERE id=p_room_id;
    RETURN jsonb_build_object('success',true,'game_over',true,'winner_player_id',v_attacker.id);
  END IF;
  UPDATE public.game_states SET current_turn_seat=v_next_seat,
    turn_number=v_state.turn_number+1,
    current_round=v_state.current_round+CASE WHEN v_wrapped THEN 1 ELSE 0 END,
    open_pile=v_pile,updated_at=now()
  WHERE room_id=p_room_id;

  RETURN jsonb_build_object('success',true,'eliminated',v_eliminated,
    'defended',NOT v_eliminated,'next_seat',v_next_seat);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.respond_to_elimination(uuid,text,text[],text) TO authenticated;


-- Let the authenticated room host resolve an attack against a bot.
-- The bot chooses a legal defence from its own hand; if none is available it accepts elimination.
CREATE OR REPLACE FUNCTION public.run_bot_elimination_response(p_room_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_attack record;
  v_bot record;
  v_hand jsonb;
  v_card jsonb;
  v_silkworm text;
  v_tsubaki text;
  v_bonsai text;
  v_points_ids text[] := ARRAY[]::text[];
  v_bonsai_ids text[] := ARRAY[]::text[];
  v_extra text;
  v_points integer := 0;
  v_bonsai_points integer := 0;
  v_action text := 'accept';
  v_ids text[] := ARRAY[]::text[];
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.game_rooms
    WHERE id=p_room_id AND host_id=auth.uid()
  ) THEN
    RAISE EXCEPTION 'Only the room host can run bot decisions.';
  END IF;

  SELECT * INTO v_attack
  FROM public.game_pending_attacks
  WHERE room_id=p_room_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success',true,'no_pending_attack',true);
  END IF;

  SELECT rp.* INTO v_bot
  FROM public.room_players rp
  WHERE rp.id=v_attack.target_player_id
    AND rp.room_id=p_room_id AND rp.is_bot;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success',true,'not_a_bot_target',true);
  END IF;

  SELECT cards INTO v_hand
  FROM public.player_hands
  WHERE room_id=p_room_id AND room_player_id=v_bot.id
  FOR UPDATE;
  v_hand := COALESCE(v_hand,'[]'::jsonb);

  FOR v_card IN SELECT value FROM jsonb_array_elements(v_hand) LOOP
    IF v_card->>'id'='silkworm_shield' THEN v_silkworm:=v_card->>'id'; END IF;
    IF v_card->>'id'='tsubaki_flower' THEN v_tsubaki:=v_card->>'id'; END IF;
    IF v_card->>'id'='bonsai' THEN v_bonsai:=v_card->>'id'; END IF;
    IF v_card->>'category' IN ('season','weather') THEN
      v_points := v_points + COALESCE((v_card->>'points')::integer,(v_card->>'number')::integer,0);
      v_points_ids := array_append(v_points_ids,v_card->>'id');
    ELSIF v_card->>'id' NOT IN ('silkworm_shield','tsubaki_flower','bonsai') THEN
      v_extra:=v_card->>'id';
    END IF;
  END LOOP;

  IF v_attack.attack_kind IN ('nure_onna','nure_sensei') THEN
    IF v_silkworm IS NOT NULL THEN
      v_action:='silkworm';
      v_ids:=ARRAY[v_silkworm];
    END IF;
  ELSIF v_points>=21 THEN
    v_action:='points';
    v_ids:=v_points_ids;
  ELSIF v_silkworm IS NOT NULL THEN
    v_action:='silkworm';
    v_ids:=ARRAY[v_silkworm];
  ELSIF v_tsubaki IS NOT NULL THEN
    v_action:='tsubaki';
    v_ids:=ARRAY[v_tsubaki];
  ELSIF v_bonsai IS NOT NULL THEN
    IF v_points>=7 THEN
      v_action:='bonsai';
      v_ids:=array_prepend(v_bonsai,v_points_ids);
    ELSIF v_extra IS NOT NULL THEN
      v_action:='bonsai';
      v_ids:=ARRAY[v_bonsai,v_extra];
    END IF;
  END IF;

  RETURN public.respond_to_elimination(p_room_id,v_action,v_ids,NULL);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.run_bot_elimination_response(uuid) TO authenticated;
