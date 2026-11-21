-- Add bot support for all four collection-only special cards.
-- Bots still prefer Season cards; when none are available they use a collection
-- special when its collection can fit within the 12-card hand limit.

CREATE OR REPLACE FUNCTION public.run_bot_turn(p_room_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_host uuid;
  v_bot_id uuid;
  v_seat integer;
  v_order integer;
  v_round integer;
  v_turn integer;
  v_next_seat integer;
  v_next_order integer;
  v_draw_count integer;
  v_i integer;
  v_deck jsonb;
  v_pile jsonb;
  v_hand jsonb;
  v_new_hand jsonb;
  v_card jsonb;
  v_top jsonb;
  v_collected jsonb := '[]'::jsonb;
  v_collected_cards jsonb := '[]'::jsonb;
  v_remaining jsonb;
  v_target_hand jsonb;
  v_target_new_hand jsonb;
  v_selected jsonb;
  v_indices jsonb := '[]'::jsonb;
  v_index integer;
  v_play_index bigint;
  v_collect_count integer := 0;
  v_deck_count integer;
  v_non_nure_count integer;
  v_hand_count integer;
  v_capacity integer;
  v_opponent_cards integer;
  v_target_count integer;
  v_target record;
  v_target_id uuid;
  v_target_order integer;
  v_wrapped boolean := false;
  v_reshuffled boolean := false;
  v_collection_kind text;
BEGIN
  SELECT host_id INTO v_host
  FROM public.game_rooms
  WHERE id = p_room_id;

  IF v_host IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Only the room host can run bot turns.';
  END IF;

  SELECT current_turn_seat, current_round, turn_number, draw_deck, open_pile
  INTO v_seat, v_round, v_turn, v_deck, v_pile
  FROM public.game_states
  WHERE room_id = p_room_id AND status = 'playing'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Game is not active.';
  END IF;

  SELECT id, seat_number, turn_order
  INTO v_bot_id, v_seat, v_order
  FROM public.room_players
  WHERE room_id = p_room_id
    AND seat_number = v_seat
    AND is_bot = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'It is not a bot turn.';
  END IF;

  SELECT cards INTO v_hand
  FROM public.player_hands
  WHERE room_id = p_room_id AND room_player_id = v_bot_id
  FOR UPDATE;

  v_hand := COALESCE(v_hand, '[]'::jsonb);
  v_deck := COALESCE(v_deck, '[]'::jsonb);
  v_pile := COALESCE(v_pile, '[]'::jsonb);
  v_hand_count := jsonb_array_length(v_hand);
  v_deck_count := jsonb_array_length(v_deck);

  -- Apply the same two-card reshuffle rule as human turns.
  SELECT count(*)::integer INTO v_non_nure_count
  FROM jsonb_array_elements(v_deck) AS e(value)
  WHERE value->>'id' <> 'nure_onna';

  IF v_non_nure_count <= 2 AND jsonb_array_length(v_pile) > 0 THEN
    SELECT COALESCE(jsonb_agg(value ORDER BY random()), '[]'::jsonb)
    INTO v_deck
    FROM jsonb_array_elements(v_deck || v_pile) AS e(value);
    v_pile := '[]'::jsonb;
    v_reshuffled := true;
  END IF;

  IF v_hand_count = 0 THEN
    v_draw_count := 3;
  ELSIF v_hand_count = 1 THEN
    v_draw_count := 2;
  ELSE
    v_draw_count := 1;
  END IF;

  v_draw_count := LEAST(v_draw_count, 12 - v_hand_count);

  IF NOT v_reshuffled AND jsonb_array_length(v_pile) > 0
     AND v_non_nure_count > 2 THEN
    v_draw_count := LEAST(v_draw_count, v_non_nure_count - 2);
  END IF;

  IF v_hand_count < 12 THEN
    FOR v_i IN 1..v_draw_count LOOP
      EXIT WHEN jsonb_array_length(v_deck) = 0;
      EXIT WHEN jsonb_array_length(v_hand) >= 12;
      v_card := v_deck -> 0;
      v_deck := v_deck - 0;
      v_hand := v_hand || jsonb_build_array(v_card);
    END LOOP;
  END IF;

  v_hand_count := jsonb_array_length(v_hand);
  v_capacity := GREATEST(0, 13 - v_hand_count);

  -- Keep Season cards as the bot's first choice.
  SELECT ordinality, value INTO v_play_index, v_card
  FROM jsonb_array_elements(v_hand) WITH ORDINALITY AS e(value, ordinality)
  WHERE value->>'category' = 'season'
  ORDER BY COALESCE((value->>'points')::integer, 0),
           COALESCE((value->>'number')::integer, 99)
  LIMIT 1;

  -- If there is no Season card, prefer collection specials whose effect can
  -- legally fit in the bot's hand. Ties are resolved in a fixed preference order.
  IF v_card IS NULL THEN
    SELECT count(*)::integer INTO v_opponent_cards
    FROM public.room_players rp
    LEFT JOIN public.game_player_states gps ON gps.room_player_id = rp.id
    LEFT JOIN public.player_hands ph ON ph.room_id = p_room_id AND ph.room_player_id = rp.id
    WHERE rp.room_id = p_room_id
      AND rp.id <> v_bot_id
      AND COALESCE(gps.is_eliminated, false) = false
      AND jsonb_array_length(COALESCE(ph.cards, '[]'::jsonb)) > 0;

    SELECT ordinality, value INTO v_play_index, v_card
    FROM jsonb_array_elements(v_hand) WITH ORDINALITY AS e(value, ordinality)
    WHERE
      (value->>'id' = 'moon_rabbit' AND jsonb_array_length(v_pile) > 0 AND v_capacity > 0)
      OR (value->>'id' = 'kappa' AND jsonb_array_length(v_pile) > 0 AND v_capacity > 0)
      OR (value->>'id' = 'sakura_leaf' AND v_opponent_cards <= v_capacity)
      OR (
        value->>'id' = 'tengu'
        AND EXISTS (
          SELECT 1
          FROM public.room_players rp
          LEFT JOIN public.game_player_states gps ON gps.room_player_id = rp.id
          LEFT JOIN public.player_hands ph ON ph.room_id = p_room_id AND ph.room_player_id = rp.id
          WHERE rp.room_id = p_room_id
            AND rp.id <> v_bot_id
            AND COALESCE(gps.is_eliminated, false) = false
            AND LEAST(2, jsonb_array_length(COALESCE(ph.cards, '[]'::jsonb))) <= v_capacity
        )
      )
    ORDER BY array_position(
      ARRAY['moon_rabbit','kappa','sakura_leaf','tengu']::text[],
      value->>'id'
    )
    LIMIT 1;
  END IF;

  IF v_card IS NOT NULL THEN
    v_collection_kind := v_card->>'id';
  END IF;

  -- If no collection special is currently usable, play a normal-use special.
  IF v_card IS NULL THEN
    SELECT ordinality, value INTO v_play_index, v_card
    FROM jsonb_array_elements(v_hand) WITH ORDINALITY AS e(value, ordinality)
    WHERE value->>'id' IN (
      'sensei_man','sensei_woman','nure_onna',
      'silkworm_shield','tsubaki_flower','bonsai'
    )
    ORDER BY array_position(
      ARRAY['sensei_man','sensei_woman','nure_onna',
            'silkworm_shield','tsubaki_flower','bonsai']::text[],
      value->>'id'
    )
    LIMIT 1;
  END IF;

  IF v_card IS NULL THEN
    RAISE EXCEPTION 'Bot has no playable Season or special card.';
  END IF;

  -- Remove the played card before adding any collected cards.
  SELECT COALESCE(jsonb_agg(value ORDER BY ordinality), '[]'::jsonb)
  INTO v_new_hand
  FROM jsonb_array_elements(v_hand) WITH ORDINALITY AS e(value, ordinality)
  WHERE ordinality <> v_play_index;

  -- Season collection remains unchanged: a higher same-season card takes
  -- up to the top two cards beneath it.
  IF v_collection_kind IS NULL AND jsonb_array_length(v_pile) > 0
     AND v_card->>'category' = 'season' THEN
    v_top := v_pile -> (jsonb_array_length(v_pile) - 1);
    IF v_top->>'category' = 'season'
       AND v_top->>'season' = v_card->>'season'
       AND (v_card->>'number')::integer > (v_top->>'number')::integer THEN
      v_collect_count := LEAST(2, jsonb_array_length(v_pile), v_capacity);
      IF v_collect_count > 0 THEN
        SELECT COALESCE(jsonb_agg(value ORDER BY ordinality), '[]'::jsonb)
        INTO v_collected
        FROM jsonb_array_elements(v_pile) WITH ORDINALITY AS e(value, ordinality)
        WHERE ordinality > jsonb_array_length(v_pile) - v_collect_count;

        SELECT COALESCE(jsonb_agg(value ORDER BY ordinality), '[]'::jsonb)
        INTO v_remaining
        FROM jsonb_array_elements(v_pile) WITH ORDINALITY AS e(value, ordinality)
        WHERE ordinality <= jsonb_array_length(v_pile) - v_collect_count;

        v_new_hand := v_new_hand || v_collected;
        v_pile := v_remaining;
        v_collected_cards := v_collected;
      END IF;
    END IF;
  END IF;

  -- Kappa: take one randomly chosen card from anywhere in the Open Pile.
  IF v_collection_kind = 'kappa' AND jsonb_array_length(v_pile) > 0 AND v_capacity > 0 THEN
    v_index := floor(random() * jsonb_array_length(v_pile))::integer;
    SELECT value INTO v_selected
    FROM jsonb_array_elements(v_pile) WITH ORDINALITY AS e(value, ordinality)
    WHERE ordinality = v_index + 1;

    SELECT COALESCE(jsonb_agg(value ORDER BY ordinality), '[]'::jsonb)
    INTO v_remaining
    FROM jsonb_array_elements(v_pile) WITH ORDINALITY AS e(value, ordinality)
    WHERE ordinality <> v_index + 1;

    v_pile := v_remaining;
    v_new_hand := v_new_hand || jsonb_build_array(v_selected);
    v_collected_cards := v_collected_cards || jsonb_build_array(v_selected);
    v_collect_count := 1;
  END IF;

  -- Moon Rabbit: collect up to the top three cards, without exceeding 12 cards.
  IF v_collection_kind = 'moon_rabbit' AND jsonb_array_length(v_pile) > 0 AND v_capacity > 0 THEN
    v_collect_count := LEAST(3, jsonb_array_length(v_pile), v_capacity);

    SELECT COALESCE(jsonb_agg(value ORDER BY ordinality), '[]'::jsonb)
    INTO v_collected
    FROM jsonb_array_elements(v_pile) WITH ORDINALITY AS e(value, ordinality)
    WHERE ordinality > jsonb_array_length(v_pile) - v_collect_count;

    SELECT COALESCE(jsonb_agg(value ORDER BY ordinality), '[]'::jsonb)
    INTO v_remaining
    FROM jsonb_array_elements(v_pile) WITH ORDINALITY AS e(value, ordinality)
    WHERE ordinality <= jsonb_array_length(v_pile) - v_collect_count;

    v_pile := v_remaining;
    v_new_hand := v_new_hand || v_collected;
    v_collected_cards := v_collected;
  END IF;

  -- Sakura Leaf: take one random hidden card from every active opponent
  -- who has a card. It is selected only when all such cards fit in hand.
  IF v_collection_kind = 'sakura_leaf' THEN
    FOR v_target IN
      SELECT rp.id, rp.turn_order
      FROM public.room_players rp
      LEFT JOIN public.game_player_states gps ON gps.room_player_id = rp.id
      WHERE rp.room_id = p_room_id
        AND rp.id <> v_bot_id
        AND COALESCE(gps.is_eliminated, false) = false
      ORDER BY rp.turn_order
    LOOP
      SELECT cards INTO v_target_hand
      FROM public.player_hands
      WHERE room_id = p_room_id AND room_player_id = v_target.id
      FOR UPDATE;
      v_target_hand := COALESCE(v_target_hand, '[]'::jsonb);

      IF jsonb_array_length(v_target_hand) > 0 THEN
        v_index := floor(random() * jsonb_array_length(v_target_hand))::integer;
        SELECT value INTO v_selected
        FROM jsonb_array_elements(v_target_hand) WITH ORDINALITY AS e(value, ordinality)
        WHERE ordinality = v_index + 1;

        SELECT COALESCE(jsonb_agg(value ORDER BY ordinality), '[]'::jsonb)
        INTO v_target_new_hand
        FROM jsonb_array_elements(v_target_hand) WITH ORDINALITY AS e(value, ordinality)
        WHERE ordinality <> v_index + 1;

        UPDATE public.player_hands
        SET cards = v_target_new_hand, updated_at = now()
        WHERE room_id = p_room_id AND room_player_id = v_target.id;

        v_new_hand := v_new_hand || jsonb_build_array(v_selected);
        v_collected_cards := v_collected_cards || jsonb_build_array(
          jsonb_build_object('id','hidden_card','name','Hidden card','category','hidden')
        );
        v_collect_count := v_collect_count + 1;
      END IF;
    END LOOP;
  END IF;

  -- Tengu: choose one active opponent with a hand and take up to two
  -- random hidden cards from that opponent only.
  IF v_collection_kind = 'tengu' THEN
    SELECT rp.id, jsonb_array_length(COALESCE(ph.cards, '[]'::jsonb))::integer
    INTO v_target_id, v_target_count
    FROM public.room_players rp
    LEFT JOIN public.game_player_states gps ON gps.room_player_id = rp.id
    LEFT JOIN public.player_hands ph ON ph.room_id = p_room_id AND ph.room_player_id = rp.id
    WHERE rp.room_id = p_room_id
      AND rp.id <> v_bot_id
      AND COALESCE(gps.is_eliminated, false) = false
      AND LEAST(2, jsonb_array_length(COALESCE(ph.cards, '[]'::jsonb))) <= v_capacity
    ORDER BY
      CASE WHEN jsonb_array_length(COALESCE(ph.cards, '[]'::jsonb)) > 0 THEN 0 ELSE 1 END,
      random()
    LIMIT 1;

    IF v_target_id IS NOT NULL THEN
      SELECT cards INTO v_target_hand
      FROM public.player_hands
      WHERE room_id = p_room_id AND room_player_id = v_target_id
      FOR UPDATE;
      v_target_hand := COALESCE(v_target_hand, '[]'::jsonb);
      v_collect_count := LEAST(2, jsonb_array_length(v_target_hand));

      SELECT COALESCE(jsonb_agg(card_index ORDER BY random()), '[]'::jsonb)
      INTO v_indices
      FROM (
        SELECT (ordinality - 1)::integer AS card_index
        FROM jsonb_array_elements(v_target_hand) WITH ORDINALITY AS e(value, ordinality)
        ORDER BY random()
        LIMIT v_collect_count
      ) AS chosen;

      FOR v_index IN SELECT (value::text)::integer FROM jsonb_array_elements(v_indices) LOOP
        SELECT value INTO v_selected
        FROM jsonb_array_elements(v_target_hand) WITH ORDINALITY AS e(value, ordinality)
        WHERE ordinality = v_index + 1;
        v_new_hand := v_new_hand || jsonb_build_array(v_selected);
        v_collected_cards := v_collected_cards || jsonb_build_array(
          jsonb_build_object('id','hidden_card','name','Hidden card','category','hidden')
        );
      END LOOP;

      SELECT COALESCE(jsonb_agg(value ORDER BY ordinality), '[]'::jsonb)
      INTO v_target_new_hand
      FROM jsonb_array_elements(v_target_hand) WITH ORDINALITY AS e(value, ordinality)
      WHERE NOT ((ordinality - 1)::integer IN (
        SELECT (value::text)::integer FROM jsonb_array_elements(v_indices)
      ));

      UPDATE public.player_hands
      SET cards = v_target_new_hand, updated_at = now()
      WHERE room_id = p_room_id AND room_player_id = v_target_id;
    END IF;
  END IF;

  -- Nure-Onna returns to the bottom of the Draw Deck; all other played
  -- cards remain on top of the Open Pile.
  IF v_card->>'id' = 'nure_onna' THEN
    v_deck := v_deck || jsonb_build_array(v_card);
  ELSE
    v_pile := v_pile || jsonb_build_array(v_card);
  END IF;

  -- Advance clockwise, skipping eliminated players.
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
      last_draw_turn_number = v_turn + 1,
      updated_at = now()
  WHERE room_id = p_room_id AND room_player_id = v_bot_id;

  UPDATE public.game_states
  SET draw_deck = v_deck,
      open_pile = v_pile,
      current_turn_seat = v_next_seat,
      turn_number = v_turn + 1,
      current_round = v_round + CASE WHEN v_wrapped THEN 1 ELSE 0 END,
      updated_at = now()
  WHERE room_id = p_room_id;

  -- Hidden-card collection effects are represented as hidden cards in the
  -- animation event, matching the human Sakura Leaf and Tengu behaviour.
  IF v_collection_kind IN ('sakura_leaf','tengu') AND v_collect_count > 0 THEN
    UPDATE public.game_animation_events
    SET collected_cards = v_collected_cards,
        recipient_player_id = v_bot_id
    WHERE id = (
      SELECT id
      FROM public.game_animation_events
      WHERE room_id = p_room_id AND actor_player_id = v_bot_id
      ORDER BY id DESC
      LIMIT 1
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'played_card', v_card->>'name',
    'cards_drawn', v_draw_count,
    'cards_collected', v_collect_count,
    'collection_ability', v_collection_kind,
    'reshuffled', v_reshuffled,
    'next_seat', v_next_seat
  );
END;
$function$;
