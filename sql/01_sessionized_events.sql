-- =============================================================================
-- 01_sessionized_events.sql
-- One shared sessionization layer. Every downstream module reads from this view
-- instead of re-deriving sessions, so the definition lives in exactly one place.
--
-- Session rule: a new session starts on a user's first event, or when more than
-- 30 minutes have passed since that user's previous event.
--
-- event_id is the tiebreaker in every ORDER BY: events can share a timestamp to
-- the second, and without it the session sequence would be non-deterministic.
-- =============================================================================

CREATE OR REPLACE VIEW sessionized_events AS
WITH event_gaps AS (
    SELECT
        event_id,
        user_id,
        event_name,
        event_timestamp,
        platform,
        LAG(event_timestamp) OVER (
            PARTITION BY user_id
            ORDER BY event_timestamp, event_id
        ) AS prev_event_timestamp
    FROM user_events
),

session_starts AS (
    SELECT
        *,
        CASE
            WHEN prev_event_timestamp IS NULL                                   THEN 1
            WHEN event_timestamp - prev_event_timestamp > INTERVAL '30 minutes' THEN 1
            ELSE 0
        END AS is_session_start
    FROM event_gaps
),

session_numbers AS (
    SELECT
        *,
        SUM(is_session_start) OVER (
            PARTITION BY user_id
            ORDER BY event_timestamp, event_id
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS user_session_number
    FROM session_starts
)

SELECT
    event_id,
    user_id,
    event_name,
    event_timestamp,
    platform,
    user_session_number,
    user_id || '_s' || user_session_number AS session_id,
    ROW_NUMBER() OVER (
        PARTITION BY user_id, user_session_number
        ORDER BY event_timestamp, event_id
    ) AS event_seq_in_session,
    is_session_start = 1 AS is_session_start
FROM session_numbers;
