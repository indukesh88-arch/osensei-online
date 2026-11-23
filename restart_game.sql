-- Allow the room host to start a rematch in the same room after a game finishes.
-- Existing room_players rows are preserved, so the same players keep their seats.

CREATE OR REPLACE FUNCTION public.restart_game(p_room_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id uuid;
    v_host_id uuid;
    v_room_status text;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'You must be logged in to restart the game';
    END IF;

    SELECT host_id, status
      INTO v_host_id, v_room_status
      FROM public.game_rooms
     WHERE id = p_room_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room not found';
    END IF;

    IF v_host_id <> v_user_id THEN
        RAISE EXCEPTION 'Only the room host can start another game';
    END IF;

    IF v_room_status <> 'finished' THEN
        RAISE EXCEPTION 'A new game can only be started after the current game finishes';
    END IF;

    -- start_game already contains the canonical deck-building, dealing,
    -- turn-order, player-state and game-state initialization logic.
    -- Temporarily return the room to waiting so start_game can run.
    UPDATE public.game_rooms
       SET status = 'waiting'
     WHERE id = p_room_id;

    DELETE FROM public.game_pending_attacks
     WHERE room_id = p_room_id;

    UPDATE public.player_hands
       SET last_draw_turn_number = NULL,
           updated_at = now()
     WHERE room_id = p_room_id;

    PERFORM public.start_game(p_room_id);

    -- Do not replay card animations from the previous match (or the
    -- game-state reset) when clients enter the new match.
    DELETE FROM public.game_animation_events
     WHERE room_id = p_room_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.restart_game(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.restart_game(uuid) TO authenticated;
