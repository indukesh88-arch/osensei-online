-- Ōsensei: automatically reshuffle the open pile when the draw deck
-- reaches its final two cards.
--
-- The reshuffle is silent: no cards are dealt to players and no animation
-- event is created here. All cards still in NEW.open_pile are shuffled
-- together with the remaining draw deck, then the open pile is cleared.
--
-- The 3 -> 0 condition also covers a bot turn that consumes all three
-- remaining cards in one batch; normal human draws trigger at 2 -> 1.

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
    IF NEW.draw_deck IS NOT DISTINCT FROM OLD.draw_deck THEN
        RETURN NEW;
    END IF;

    v_old_count := jsonb_array_length(COALESCE(OLD.draw_deck, '[]'::jsonb));
    v_new_count := jsonb_array_length(COALESCE(NEW.draw_deck, '[]'::jsonb));
    v_pile_count := jsonb_array_length(COALESCE(NEW.open_pile, '[]'::jsonb));

    -- Trigger on a normal draw that starts with 2 or fewer cards.
    -- Also catch a bot batch that consumes all 3 remaining cards at once.
    IF v_new_count >= v_old_count
       OR NOT (v_old_count <= 2 OR (v_old_count = 3 AND v_new_count = 0))
       OR v_pile_count = 0 THEN
        RETURN NEW;
    END IF;

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
BEFORE UPDATE OF draw_deck ON public.game_states
FOR EACH ROW
EXECUTE FUNCTION public.reshuffle_open_pile_when_draw_deck_low();
