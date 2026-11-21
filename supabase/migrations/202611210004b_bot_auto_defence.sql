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


-- Allow the attack RPC to select active bot seats as targets.
