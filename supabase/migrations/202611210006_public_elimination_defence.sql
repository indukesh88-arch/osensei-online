-- Correct normal elimination attacks: Season/Weather points totaling 21+ are sufficient.
-- Sensei and Nure-Onna remain optional special attack cards with their specific rules.
CREATE OR REPLACE FUNCTION public.play_elimination_attack(
  p_room_id uuid,
  p_card_ids text[],
  p_target_player_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_state record;
  v_attacker record;
  v_target record;
  v_hand jsonb;
  v_new_hand jsonb := '[]'::jsonb;
  v_selected jsonb := '[]'::jsonb;
  v_to_pile jsonb := '[]'::jsonb;
  v_deck jsonb;
  v_card jsonb;
  v_id text;
  v_points integer := 0;
  v_has_sensei_man boolean := false;
  v_has_sensei_woman boolean := false;
  v_has_nure boolean := false;
  v_kind text;
  v_expected_target_order integer;
BEGIN
  IF COALESCE(array_length(p_card_ids,1),0) < 2 THEN
    RAISE EXCEPTION 'Select at least two Season/Weather cards totaling 21 or more points.';
  END IF;
  IF (SELECT count(DISTINCT x) FROM unnest(p_card_ids) x) <> array_length(p_card_ids,1) THEN
    RAISE EXCEPTION 'A card can only be selected once.';
  END IF;

  SELECT * INTO v_state
  FROM public.game_states
  WHERE room_id=p_room_id AND status='playing'
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Game is not active.'; END IF;
  IF v_state.current_round < 3 THEN
    RAISE EXCEPTION 'Elimination attacks become available from round 3.';
  END IF;

  SELECT * INTO v_attacker
  FROM public.room_players
  WHERE room_id=p_room_id AND user_id=auth.uid()
    AND seat_number=v_state.current_turn_seat AND NOT is_bot;
  IF NOT FOUND THEN RAISE EXCEPTION 'It is not your turn.'; END IF;

  SELECT * INTO v_target
  FROM public.room_players rp
  LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
  WHERE rp.room_id=p_room_id AND rp.id=p_target_player_id
    AND rp.id<>v_attacker.id AND COALESCE(gps.is_eliminated,false)=false;
  IF NOT FOUND THEN RAISE EXCEPTION 'Choose an active opponent.'; END IF;

  IF EXISTS (SELECT 1 FROM public.game_pending_attacks WHERE room_id=p_room_id) THEN
    RAISE EXCEPTION 'An elimination attack is already awaiting a response.';
  END IF;

  SELECT cards INTO v_hand FROM public.player_hands
  WHERE room_id=p_room_id AND room_player_id=v_attacker.id FOR UPDATE;
  v_hand := COALESCE(v_hand,'[]'::jsonb);
  v_deck := COALESCE(v_state.draw_deck,'[]'::jsonb);

  FOREACH v_id IN ARRAY p_card_ids LOOP
    SELECT value INTO v_card
    FROM jsonb_array_elements(v_hand)
    WHERE value->>'id'=v_id;
    IF v_card IS NULL THEN RAISE EXCEPTION 'A selected card is not in your hand.'; END IF;
    v_selected := v_selected || jsonb_build_array(v_card);
    IF v_card->>'category' IN ('season','weather') THEN
      v_points := v_points + COALESCE((v_card->>'points')::integer,(v_card->>'number')::integer,0);
    ELSIF v_card->>'id'='sensei_man' THEN
      v_has_sensei_man := true;
    ELSIF v_card->>'id'='sensei_woman' THEN
      v_has_sensei_woman := true;
    ELSIF v_card->>'id'='nure_onna' THEN
      v_has_nure := true;
    ELSE
      RAISE EXCEPTION 'Elimination attacks use Season/Weather cards, optionally with Sensei or Nure-Onna.';
    END IF;
  END LOOP;

  IF v_has_sensei_man AND v_has_sensei_woman THEN
    RAISE EXCEPTION 'You cannot combine both Sensei cards in one attack.';
  END IF;

  -- A normal elimination attack needs only Season/Weather cards totaling 21+.
  -- Sensei and Nure-Onna remain optional special attack modifiers.
  IF NOT v_has_nure AND NOT v_has_sensei_man AND NOT v_has_sensei_woman THEN
    IF v_points < 21 THEN
      RAISE EXCEPTION 'A normal elimination attack requires Season/Weather cards totaling at least 21 points.';
    END IF;
    v_kind := 'standard';
  ELSIF v_has_nure THEN
    IF v_has_sensei_man OR v_has_sensei_woman THEN
      IF v_points < 14 THEN RAISE EXCEPTION 'Nure-Onna with Sensei requires at least 14 points.'; END IF;
      v_kind := CASE WHEN v_has_sensei_man THEN 'nure_sensei' ELSE 'nure_sensei' END;
      IF v_has_sensei_man THEN
        SELECT rp.id INTO v_target.id FROM public.room_players rp
        LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
        WHERE rp.room_id=p_room_id AND rp.turn_order>v_attacker.turn_order
          AND COALESCE(gps.is_eliminated,false)=false
        ORDER BY rp.turn_order LIMIT 1;
        IF v_target.id IS NULL THEN
          SELECT rp.id INTO v_target.id FROM public.room_players rp
          LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
          WHERE rp.room_id=p_room_id AND COALESCE(gps.is_eliminated,false)=false
          ORDER BY rp.turn_order LIMIT 1;
        END IF;
      ELSE
        SELECT rp.id INTO v_target.id FROM public.room_players rp
        LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
        WHERE rp.room_id=p_room_id AND rp.turn_order<v_attacker.turn_order
          AND COALESCE(gps.is_eliminated,false)=false
        ORDER BY rp.turn_order DESC LIMIT 1;
        IF v_target.id IS NULL THEN
          SELECT rp.id INTO v_target.id FROM public.room_players rp
          LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
          WHERE rp.room_id=p_room_id AND COALESCE(gps.is_eliminated,false)=false
          ORDER BY rp.turn_order DESC LIMIT 1;
        END IF;
      END IF;
      IF v_target.id IS NULL OR v_target.id<>p_target_player_id THEN
        RAISE EXCEPTION 'Nure-Onna with Sensei must target the player indicated by the Sensei card.';
      END IF;
    ELSE
      IF v_points < 21 THEN RAISE EXCEPTION 'Nure-Onna alone requires at least 21 points.'; END IF;
      v_kind := 'nure_onna';
    END IF;
  ELSIF v_has_sensei_man OR v_has_sensei_woman THEN
    IF v_points < 14 THEN RAISE EXCEPTION 'Sensei attacks require at least 14 points.'; END IF;
    v_kind := CASE WHEN v_has_sensei_man THEN 'sensei_man' ELSE 'sensei_woman' END;
    IF v_has_sensei_man THEN
      SELECT rp.id INTO v_target.id FROM public.room_players rp
      LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
      WHERE rp.room_id=p_room_id AND rp.turn_order>v_attacker.turn_order
        AND COALESCE(gps.is_eliminated,false)=false
      ORDER BY rp.turn_order LIMIT 1;
      IF v_target.id IS NULL THEN
        SELECT rp.id INTO v_target.id FROM public.room_players rp
        LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
        WHERE rp.room_id=p_room_id AND COALESCE(gps.is_eliminated,false)=false
        ORDER BY rp.turn_order LIMIT 1;
      END IF;
    ELSE
      SELECT rp.id INTO v_target.id FROM public.room_players rp
      LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
      WHERE rp.room_id=p_room_id AND rp.turn_order<v_attacker.turn_order
        AND COALESCE(gps.is_eliminated,false)=false
      ORDER BY rp.turn_order DESC LIMIT 1;
      IF v_target.id IS NULL THEN
        SELECT rp.id INTO v_target.id FROM public.room_players rp
        LEFT JOIN public.game_player_states gps ON gps.room_player_id=rp.id
        WHERE rp.room_id=p_room_id AND COALESCE(gps.is_eliminated,false)=false
        ORDER BY rp.turn_order DESC LIMIT 1;
      END IF;
    END IF;
    IF v_target.id IS NULL OR v_target.id<>p_target_player_id THEN
      RAISE EXCEPTION 'Choose the player indicated by the Sensei card.';
    END IF;
  ELSE
    RAISE EXCEPTION 'Invalid elimination combination.';
  END IF;



  -- Remove the selected cards. Nure-Onna goes to the bottom of the draw deck;
  -- all other attack cards are placed on the open pile in the chosen order.
  FOR v_card IN SELECT value FROM jsonb_array_elements(v_selected) LOOP
    IF v_card->>'id'='nure_onna' THEN
      v_deck := v_deck || jsonb_build_array(v_card);
    ELSE
      v_to_pile := v_to_pile || jsonb_build_array(v_card);
    END IF;
  END LOOP;
  SELECT COALESCE(jsonb_agg(h.value ORDER BY h.ordinality),'[]'::jsonb)
  INTO v_new_hand
  FROM jsonb_array_elements(v_hand) WITH ORDINALITY h(value,ordinality)
  WHERE NOT (h.value->>'id'=ANY(p_card_ids));

  UPDATE public.player_hands SET cards=v_new_hand,updated_at=now()
  WHERE room_id=p_room_id AND room_player_id=v_attacker.id;
  UPDATE public.game_states SET draw_deck=v_deck,
    open_pile=COALESCE(open_pile,'[]'::jsonb)||v_to_pile,updated_at=now()
  WHERE room_id=p_room_id;

  INSERT INTO public.game_pending_attacks(
    room_id,attacker_player_id,target_player_id,original_target_player_id,
    attack_cards,attack_points,attack_kind
  ) VALUES (
    p_room_id,v_attacker.id,p_target_player_id,p_target_player_id,
    v_selected,v_points,v_kind
  );

  RETURN jsonb_build_object('success',true,'awaiting_defence',true,
    'target_player_id',p_target_player_id,'attack_points',v_points,
    'attack_kind',v_kind);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.play_elimination_attack(uuid,text[],uuid) TO authenticated;


-- Publicly stage a defence so every room player can inspect the exact cards
-- before the targeted player confirms the response.
ALTER TABLE public.game_pending_attacks
  ADD COLUMN IF NOT EXISTS defence_action text,
  ADD COLUMN IF NOT EXISTS defence_card_ids text[] NOT NULL DEFAULT ARRAY[]::text[],
  ADD COLUMN IF NOT EXISTS defence_cards jsonb NOT NULL DEFAULT '[]'::jsonb;

CREATE OR REPLACE FUNCTION public.stage_elimination_defence(
  p_room_id uuid,
  p_action text,
  p_defence_card_ids text[] DEFAULT ARRAY[]::text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_attack record;
  v_defender record;
  v_hand jsonb;
  v_cards jsonb := '[]'::jsonb;
  v_count integer := 0;
BEGIN
  SELECT * INTO v_attack
  FROM public.game_pending_attacks
  WHERE room_id=p_room_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'There is no pending elimination attack.'; END IF;

  SELECT * INTO v_defender
  FROM public.room_players rp
  WHERE rp.id=v_attack.target_player_id
    AND rp.room_id=p_room_id
    AND (
      (NOT rp.is_bot AND rp.user_id=auth.uid())
      OR
      (rp.is_bot AND EXISTS (
        SELECT 1 FROM public.game_rooms gr
        WHERE gr.id=p_room_id AND gr.host_id=auth.uid()
      ))
    );
  IF NOT FOUND THEN RAISE EXCEPTION 'Only the targeted player or room host for a bot can choose the defence.'; END IF;

  IF p_action NOT IN ('accept','points','silkworm','tsubaki','bonsai') THEN
    RAISE EXCEPTION 'Unknown defence action.';
  END IF;

  IF p_action='accept' THEN
    IF COALESCE(array_length(p_defence_card_ids,1),0)<>0 THEN
      RAISE EXCEPTION 'Accepting elimination cannot include defence cards.';
    END IF;
  ELSE
    IF COALESCE(array_length(p_defence_card_ids,1),0)=0 THEN
      RAISE EXCEPTION 'Select the defence card or cards first.';
    END IF;
    IF (SELECT count(DISTINCT x) FROM unnest(p_defence_card_ids) x) <> array_length(p_defence_card_ids,1) THEN
      RAISE EXCEPTION 'A defence card can only be selected once.';
    END IF;

    SELECT cards INTO v_hand
    FROM public.player_hands
    WHERE room_id=p_room_id AND room_player_id=v_defender.id
    FOR UPDATE;
    v_hand:=COALESCE(v_hand,'[]'::jsonb);

    SELECT count(*),COALESCE(
      jsonb_agg(h.value ORDER BY h.ordinality),'[]'::jsonb
    )
    INTO v_count,v_cards
    FROM jsonb_array_elements(v_hand) WITH ORDINALITY h(value,ordinality)
    WHERE h.value->>'id'=ANY(p_defence_card_ids);

    IF v_count<>array_length(p_defence_card_ids,1) THEN
      RAISE EXCEPTION 'A selected defence card is not in your hand.';
    END IF;
  END IF;

  UPDATE public.game_pending_attacks
  SET defence_action=p_action,
      defence_card_ids=COALESCE(p_defence_card_ids,ARRAY[]::text[]),
      defence_cards=v_cards
  WHERE room_id=p_room_id;

  RETURN jsonb_build_object(
    'success',true,'staged',true,
    'defence_action',p_action,'defence_cards',v_cards
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.stage_elimination_defence(uuid,text,text[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.confirm_elimination_defence(p_room_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_attack record;
  v_defender record;
  v_result jsonb;
BEGIN
  SELECT * INTO v_attack
  FROM public.game_pending_attacks
  WHERE room_id=p_room_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'There is no pending elimination attack.'; END IF;
  IF v_attack.defence_action IS NULL THEN
    RAISE EXCEPTION 'No defence has been staged yet.';
  END IF;

  SELECT * INTO v_defender
  FROM public.room_players rp
  WHERE rp.id=v_attack.target_player_id
    AND rp.room_id=p_room_id
    AND (
      (NOT rp.is_bot AND rp.user_id=auth.uid())
      OR
      (rp.is_bot AND EXISTS (
        SELECT 1 FROM public.game_rooms gr
        WHERE gr.id=p_room_id AND gr.host_id=auth.uid()
      ))
    );
  IF NOT FOUND THEN RAISE EXCEPTION 'Only the targeted player or room host for a bot can confirm the defence.'; END IF;

  v_result:=public.respond_to_elimination(
    p_room_id,v_attack.defence_action,v_attack.defence_card_ids,NULL
  );

  -- Tsubaki redirects the pending attack instead of resolving it. Clear the
  -- staged response so the newly targeted player can choose their response.
  IF COALESCE((v_result->>'redirected')::boolean,false) THEN
    UPDATE public.game_pending_attacks
    SET defence_action=NULL,
        defence_card_ids=ARRAY[]::text[],
        defence_cards='[]'::jsonb
    WHERE room_id=p_room_id;
  END IF;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.confirm_elimination_defence(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.cancel_staged_elimination_defence(p_room_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_attack record;
BEGIN
  SELECT * INTO v_attack
  FROM public.game_pending_attacks
  WHERE room_id=p_room_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'There is no pending elimination attack.'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.room_players rp
    WHERE rp.id=v_attack.target_player_id
      AND rp.room_id=p_room_id
      AND (
        (NOT rp.is_bot AND rp.user_id=auth.uid())
        OR
        (rp.is_bot AND EXISTS (
          SELECT 1 FROM public.game_rooms gr
          WHERE gr.id=p_room_id AND gr.host_id=auth.uid()
        ))
      )
  ) THEN
    RAISE EXCEPTION 'Only the targeted player or room host for a bot can cancel the staged defence.';
  END IF;

  UPDATE public.game_pending_attacks
  SET defence_action=NULL,
      defence_card_ids=ARRAY[]::text[],
      defence_cards='[]'::jsonb
  WHERE room_id=p_room_id;

  RETURN jsonb_build_object('success',true,'cancelled',true);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.cancel_staged_elimination_defence(uuid) TO authenticated;

-- Bots choose their defence first; the room then displays the exact cards
-- before the host confirms the bot's response.

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

  RETURN public.stage_elimination_defence(p_room_id,v_action,v_ids);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.run_bot_elimination_response(uuid) TO authenticated;


-- Allow the attack RPC to select active bot seats as targets.
