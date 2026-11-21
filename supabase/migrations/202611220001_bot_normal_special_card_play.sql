-- Bot turn support: allow normal-play special cards and use the current reshuffle rule.
-- Collection-only special abilities remain separate and are not treated as normal plays.

CREATE OR REPLACE FUNCTION public.run_bot_turn(p_room_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_host uuid;
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
v_collected jsonb;
v_remaining jsonb;
v_play_index bigint;
v_collect_count integer := 0;
v_deck_count integer;
v_non_nure_count integer;
v_hand_count integer;
v_wrapped boolean := false;
v_reshuffled boolean := false;
BEGIN
SELECT host_id INTO v_host
FROM public.game_rooms
WHERE id = p_room_id;

IF v_host IS DISTINCT FROM auth.uid() THEN
RAISE EXCEPTION 'Only the room host can run bot turns.';
END IF;

SELECT current_turn_seat, current_round, turn_number,
draw_deck, open_pile
INTO v_seat, v_round, v_turn, v_deck, v_pile
FROM public.game_states
WHERE room_id = p_room_id AND status = 'playing'
FOR UPDATE;

IF NOT FOUND THEN
RAISE EXCEPTION 'Game is not active.';
END IF;

SELECT seat_number, turn_order
INTO v_seat, v_order
FROM public.room_players
WHERE room_id = p_room_id
AND seat_number = v_seat
AND is_bot = true;

IF NOT FOUND THEN
RAISE EXCEPTION 'It is not a bot turn.';
END IF;

SELECT cards INTO v_hand
FROM public.player_hands
WHERE room_id = p_room_id
AND room_player_id = (
SELECT id FROM public.room_players
WHERE room_id = p_room_id
AND seat_number = v_seat
AND is_bot = true
)
FOR UPDATE;

v_hand := COALESCE(v_hand, '[]'::jsonb);
v_deck := COALESCE(v_deck, '[]'::jsonb);
v_pile := COALESCE(v_pile, '[]'::jsonb);

v_hand_count := jsonb_array_length(v_hand);
v_deck_count := jsonb_array_length(v_deck);

-- Match the current two-card reshuffle rule used by human turns.
SELECT count(*)::integer
INTO v_non_nure_count
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

-- Keep two non-Nure-Onna cards in the deck when an Open Pile is waiting
-- to be reshuffled on the next turn.
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

-- Prefer an ordinary Season card when available.
SELECT ordinality, value
INTO v_play_index, v_card
FROM jsonb_array_elements(v_hand)
WITH ORDINALITY AS e(value, ordinality)
WHERE value->>'category' = 'season'
ORDER BY
    COALESCE((value->>'points')::integer, 0),
    COALESCE((value->>'number')::integer, 99)
LIMIT 1;

-- If the bot has no Season card, it may play these special cards normally.
-- Nure-Onna returns to the bottom of the Draw Deck; the others go on the Open Pile.
IF v_card IS NULL THEN
    SELECT ordinality, value
    INTO v_play_index, v_card
    FROM jsonb_array_elements(v_hand)
    WITH ORDINALITY AS e(value, ordinality)
    WHERE value->>'id' IN (
        'sensei_man',
        'sensei_woman',
        'nure_onna',
        'silkworm_shield',
        'tsubaki_flower',
        'bonsai'
    )
    ORDER BY array_position(
        ARRAY[
            'sensei_man',
            'sensei_woman',
            'nure_onna',
            'silkworm_shield',
            'tsubaki_flower',
            'bonsai'
        ]::text[],
        value->>'id'
    )
    LIMIT 1;
END IF;

IF v_card IS NULL THEN
    RAISE EXCEPTION
        'Bot has no playable Season or normal-play special card.';
END IF;

SELECT COALESCE(
jsonb_agg(value ORDER BY ordinality),
'[]'::jsonb
)
INTO v_new_hand
FROM jsonb_array_elements(v_hand)
WITH ORDINALITY AS e(value, ordinality)
WHERE ordinality <> v_play_index;

-- Season collection: a higher number of the same season
-- collects up to the top two cards beneath it.
IF jsonb_array_length(v_pile) > 0 THEN
v_top := v_pile -> (jsonb_array_length(v_pile) - 1);

IF v_top->>'category' = 'season'
AND v_top->>'season' = v_card->>'season'
AND (v_card->>'number')::integer >
(v_top->>'number')::integer THEN

v_collect_count :=
LEAST(2, jsonb_array_length(v_pile));

SELECT COALESCE(
jsonb_agg(value ORDER BY ordinality),
'[]'::jsonb
)
INTO v_collected
FROM jsonb_array_elements(v_pile)
WITH ORDINALITY AS e(value, ordinality)
WHERE ordinality >
jsonb_array_length(v_pile) - v_collect_count;

SELECT COALESCE(
jsonb_agg(value ORDER BY ordinality),
'[]'::jsonb
)
INTO v_remaining
FROM jsonb_array_elements(v_pile)
WITH ORDINALITY AS e(value, ordinality)
WHERE ordinality <=
jsonb_array_length(v_pile) - v_collect_count;

v_new_hand := v_new_hand || v_collected;
v_pile := v_remaining;
END IF;
END IF;

IF v_card->>'id' = 'nure_onna' THEN
    -- Nure-Onna always returns to the bottom of the Draw Deck after a normal play.
    v_deck := v_deck || jsonb_build_array(v_card);
ELSE
    v_pile := v_pile || jsonb_build_array(v_card);
END IF;

-- Find the next non-eliminated player in randomized order.
SELECT rp.seat_number, rp.turn_order
INTO v_next_seat, v_next_order
FROM public.room_players rp
LEFT JOIN public.game_player_states gps
ON gps.room_player_id = rp.id
WHERE rp.room_id = p_room_id
AND rp.turn_order > v_order
AND COALESCE(gps.is_eliminated, false) = false
ORDER BY rp.turn_order
LIMIT 1;

IF NOT FOUND THEN
SELECT rp.seat_number, rp.turn_order
INTO v_next_seat, v_next_order
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
last_draw_turn_number = v_turn + 1,
updated_at = now()
WHERE room_id = p_room_id
AND room_player_id = (
SELECT id FROM public.room_players
WHERE room_id = p_room_id
AND seat_number = v_seat
AND is_bot = true
);

UPDATE public.game_states
SET draw_deck = v_deck,
open_pile = v_pile,
current_turn_seat = v_next_seat,
turn_number = v_turn + 1,
current_round = v_round +
CASE WHEN v_wrapped THEN 1 ELSE 0 END,
updated_at = now()
WHERE room_id = p_room_id;

RETURN jsonb_build_object(
'success', true,
'played_card', v_card->>'name',
'cards_drawn', v_draw_count,
'cards_collected', v_collect_count,
'reshuffled', v_reshuffled,
'next_seat', v_next_seat
);
END;
$function$;
