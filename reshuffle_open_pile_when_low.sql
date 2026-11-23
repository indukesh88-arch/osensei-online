-- Ōsensei: silently reshuffle the open pile into the draw deck
-- whenever the draw deck is down to 2 cards or fewer.
--
-- This runs when either pile changes, so it also handles the case where
-- the draw deck reaches 0/1/2 while the open pile is temporarily empty
-- and cards are played to the open pile afterward.
--
-- A 3 -> 0 draw-deck change is also covered for a bot that draws all
-- three remaining cards in one batch.

CREATE OR REPLACE FUNCTION public.reshuffle_open_pile_when_draw_deck_low()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_old_count integer;
    v_new_count integer;
    v_pile_count integer;
    v_shuffled_deck jsonb;
BEGIN
    IF NEW.draw_deck IS NOT DISTINCT FROM OLD.draw_deck
       AND NEW.open_pile IS NOT DISTINCT FROM OLD.open_pile THEN
        RETURN NEW;
    END IF;

    v_old_count := jsonb_array_length(COALESCE(OLD.draw_deck, '[]'::jsonb));
    v_new_count := jsonb_array_length(COALESCE(NEW.draw_deck, '[]'::jsonb));
    v_pile_count := jsonb_array_length(COALESCE(NEW.open_pile, '[]'::jsonb));

    IF v_pile_count = 0
       OR NOT (v_new_count <= 2 OR (v_old_count = 3 AND v_new_count = 0)) THEN
        RETURN NEW;
    END IF;

    -- Shuffle every card still in the open pile together with any cards
    -- remaining in the draw deck. Do not deal cards or create animations.
    SELECT COALESCE(
        jsonb_agg(card ORDER BY shuffle_key),
        '[]'::jsonb
    )
    INTO v_shuffled_deck
    FROM (
        SELECT
            card,
            gen_random_uuid() AS shuffle_key
        FROM jsonb_array_elements(
            COALESCE(NEW.draw_deck, '[]'::jsonb)
            || COALESCE(NEW.open_pile, '[]'::jsonb)
        ) AS deck(card)
    ) AS shuffled;

    NEW.draw_deck := v_shuffled_deck;
    NEW.open_pile := '[]'::jsonb;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_reshuffle_open_pile_when_draw_deck_low
ON public.game_states;

CREATE TRIGGER trg_reshuffle_open_pile_when_draw_deck_low
BEFORE UPDATE OF draw_deck, open_pile ON public.game_states
FOR EACH ROW
EXECUTE FUNCTION public.reshuffle_open_pile_when_draw_deck_low();
