-- Ōsensei Online: elimination and defence state
-- This migration adds the persistent, private-to-the-room attack window.
-- Frontend/RPC gameplay integration is intentionally kept in the same feature branch.

CREATE TABLE IF NOT EXISTS public.game_pending_attacks (
  room_id uuid PRIMARY KEY REFERENCES public.game_rooms(id) ON DELETE CASCADE,
  attacker_player_id uuid NOT NULL REFERENCES public.room_players(id) ON DELETE CASCADE,
  target_player_id uuid NOT NULL REFERENCES public.room_players(id) ON DELETE CASCADE,
  original_target_player_id uuid NOT NULL REFERENCES public.room_players(id) ON DELETE CASCADE,
  attack_cards jsonb NOT NULL DEFAULT '[]'::jsonb,
  attack_points integer NOT NULL DEFAULT 0,
  attack_kind text NOT NULL CHECK (attack_kind IN ('standard','sensei_man','sensei_woman','nure_onna','nure_sensei')),
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.game_pending_attacks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Room players can read pending attacks" ON public.game_pending_attacks;
CREATE POLICY "Room players can read pending attacks"
ON public.game_pending_attacks
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.room_players rp
    WHERE rp.room_id = game_pending_attacks.room_id
      AND rp.user_id = auth.uid()
      AND NOT rp.is_bot
  )
);

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
    RAISE EXCEPTION 'Select an elimination card and at least one points card.';
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
      RAISE EXCEPTION 'Only Season, Weather, Sensei and Nure-Onna cards can form an elimination attack.';
    END IF;
  END LOOP;

  IF (v_has_sensei_man::integer + v_has_sensei_woman::integer + v_has_nure::integer) < 1 THEN
    RAISE EXCEPTION 'Include Sensei or Nure-Onna in the attack.';
  END IF;
  IF v_has_sensei_man AND v_has_sensei_woman THEN
    RAISE EXCEPTION 'You cannot combine both Sensei cards in one attack.';
  END IF;

  IF v_has_nure THEN
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

  IF NOT v_has_nure AND NOT v_has_sensei_man AND NOT v_has_sensei_woman AND v_points < 21 THEN
    RAISE EXCEPTION 'Elimination requires at least 21 points.';
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
    v_to_pile,v_points,v_kind
  );

  RETURN jsonb_build_object('success',true,'awaiting_defence',true,
    'target_player_id',p_target_player_id,'attack_points',v_points,
    'attack_kind',v_kind);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.play_elimination_attack(uuid,text[],uuid) TO authenticated;
