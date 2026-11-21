-- Shared card-play and collection animation events.
-- Events are generated from the committed game_states turn transition, so human
-- and bot plays use the same path and all room clients see the same event.

CREATE TABLE IF NOT EXISTS public.game_animation_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  room_id uuid NOT NULL REFERENCES public.game_rooms(id) ON DELETE CASCADE,
  actor_player_id uuid REFERENCES public.room_players(id) ON DELETE SET NULL,
  recipient_player_id uuid REFERENCES public.room_players(id) ON DELETE SET NULL,
  actor_name text NOT NULL DEFAULT 'A player',
  played_card jsonb,
  collected_cards jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS game_animation_events_room_created_idx
  ON public.game_animation_events (room_id, created_at DESC);

ALTER TABLE public.game_animation_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Room players can read card animation events"
  ON public.game_animation_events;

CREATE POLICY "Room players can read card animation events"
ON public.game_animation_events
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.room_players rp
    WHERE rp.room_id = game_animation_events.room_id
      AND rp.user_id = auth.uid()
      AND rp.is_bot = false
  )
);

GRANT SELECT ON public.game_animation_events TO authenticated;

CREATE OR REPLACE FUNCTION public.record_card_animation_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_actor_id uuid;
  v_actor_name text;
  v_old_pile jsonb := COALESCE(OLD.open_pile, '[]'::jsonb);
  v_new_pile jsonb := COALESCE(NEW.open_pile, '[]'::jsonb);
  v_old_count integer;
  v_new_count integer;
  v_prefix integer := 0;
  v_i integer;
  v_played_card jsonb;
  v_collected_cards jsonb := '[]'::jsonb;
BEGIN
  -- A card play advances the turn number. Ignore draws and unrelated updates.
  IF NEW.turn_number IS NOT DISTINCT FROM OLD.turn_number THEN
    RETURN NEW;
  END IF;

  SELECT rp.id, rp.player_name
    INTO v_actor_id, v_actor_name
  FROM public.room_players rp
  WHERE rp.room_id = NEW.room_id
    AND rp.seat_number = OLD.current_turn_seat
  ORDER BY rp.is_bot
  LIMIT 1;

  IF v_actor_id IS NULL THEN
    RETURN NEW;
  END IF;

  v_old_count := jsonb_array_length(v_old_pile);
  v_new_count := jsonb_array_length(v_new_pile);

  IF v_new_count > 0 THEN
    -- The last card in the resulting pile is the card just played.
    v_played_card := v_new_pile -> (v_new_count - 1);

    -- Find the unchanged prefix. Any old cards after it were collected.
    WHILE v_prefix < LEAST(v_old_count, v_new_count)
      AND (v_old_pile -> v_prefix) = (v_new_pile -> v_prefix)
    LOOP
      v_prefix := v_prefix + 1;
    END LOOP;

    IF v_prefix < v_old_count THEN
      FOR v_i IN v_prefix..(v_old_count - 1) LOOP
        v_collected_cards := v_collected_cards || jsonb_build_array(v_old_pile -> v_i);
      END LOOP;
    END IF;
  ELSIF v_new_count = 0 THEN
    -- Typhoon clears the Open Pile, collects its top two, and shuffles the
    -- remainder into the Draw Deck. Its face-up played card is represented
    -- explicitly for the shared animation.
    v_played_card := jsonb_build_object(
      'id', 'typhoon',
      'name', 'Typhoon',
      'category', 'weather'
    );

    FOR v_i IN GREATEST(0, v_old_count - 2)..(v_old_count - 1) LOOP
      v_collected_cards := v_collected_cards || jsonb_build_array(v_old_pile -> v_i);
    END LOOP;
  ELSE
    RETURN NEW;
  END IF;

  INSERT INTO public.game_animation_events (
    room_id,
    actor_player_id,
    recipient_player_id,
    actor_name,
    played_card,
    collected_cards
  )
  VALUES (
    NEW.room_id,
    v_actor_id,
    v_actor_id,
    COALESCE(v_actor_name, 'A player'),
    v_played_card,
    v_collected_cards
  );

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS game_states_card_animation_event
  ON public.game_states;

CREATE TRIGGER game_states_card_animation_event
AFTER UPDATE OF open_pile, draw_deck, current_turn_seat, turn_number
ON public.game_states
FOR EACH ROW
EXECUTE FUNCTION public.record_card_animation_event();

-- Enable Supabase Realtime for the shared event stream, without failing if
-- the table is already included in the publication.
DO $publication$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (
       SELECT 1
       FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime'
         AND schemaname = 'public'
         AND tablename = 'game_animation_events'
     ) THEN
    ALTER PUBLICATION supabase_realtime
      ADD TABLE public.game_animation_events;
  END IF;
END;
$publication$;
