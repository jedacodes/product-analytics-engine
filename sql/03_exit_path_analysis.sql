-- =============================================================================
-- 03_exit_path_analysis.sql
-- Module 2: Exit-path mining for abandoned carts
--
-- Definition of an abandoned cart session: a session that contains add_to_cart
-- but no complete_purchase. Sessions where the user only browsed are excluded on
-- purpose; they never showed purchase intent, so they aren't "abandonment".
--
-- Instead of aggregating whole sessions (long sessions produce near-unique
-- strings that never rank), we take the LAST 3 events before the user left.
-- That is the part of the journey that explains the exit.
--
-- Three result sets:
--   A. Top 5 three-step exit paths among abandoned cart sessions
--   B. Final event before exit, with how often the user came back and bought
--      within 7 days (recoverable vs. lost abandonment)
--   C. Abandonment rate at the shipping-cost screen, by platform
-- =============================================================================

-- ---------------------------------------------------------------------------
-- A. Top 5 exit paths (last three events of each abandoned cart session)
-- ---------------------------------------------------------------------------
WITH session_flags AS (
    SELECT
        session_id,
        BOOL_OR(event_name = 'add_to_cart')       AS has_cart,
        BOOL_OR(event_name = 'complete_purchase') AS has_purchase
    FROM sessionized_events
    GROUP BY session_id
),

abandoned_sessions AS (
    SELECT session_id
    FROM session_flags
    WHERE has_cart AND NOT has_purchase
),

tail_events AS (
    SELECT
        se.session_id,
        se.event_name,
        se.event_seq_in_session,
        ROW_NUMBER() OVER (
            PARTITION BY se.session_id
            ORDER BY se.event_seq_in_session DESC
        ) AS steps_from_exit
    FROM sessionized_events se
    JOIN abandoned_sessions a USING (session_id)
),

exit_paths AS (
    SELECT
        session_id,
        STRING_AGG(event_name, ' > ' ORDER BY event_seq_in_session) AS exit_path
    FROM tail_events
    WHERE steps_from_exit <= 3
    GROUP BY session_id
)

SELECT
    exit_path,
    COUNT(*)                                               AS abandoned_sessions,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)     AS pct_of_cart_abandonments
FROM exit_paths
GROUP BY exit_path
ORDER BY abandoned_sessions DESC, exit_path
LIMIT 5;
-- Note: the percentage is computed over ALL abandoned cart sessions,
-- because the window function runs before LIMIT.


-- ---------------------------------------------------------------------------
-- B. Last event before exit, and how many of those users recovered
--    (purchased in a later session within 7 days)
-- ---------------------------------------------------------------------------
WITH session_bounds AS (
    SELECT
        session_id,
        user_id,
        MAX(event_timestamp)                       AS session_end,
        BOOL_OR(event_name = 'add_to_cart')        AS has_cart,
        BOOL_OR(event_name = 'complete_purchase')  AS has_purchase
    FROM sessionized_events
    GROUP BY session_id, user_id
),

abandoned_sessions AS (
    SELECT session_id, user_id, session_end
    FROM session_bounds
    WHERE has_cart AND NOT has_purchase
      -- leave 7 days of runway so recovery is observable
      AND session_end + INTERVAL '7 days' <= (SELECT MAX(event_timestamp) FROM user_events)
),

last_events AS (
    SELECT DISTINCT ON (se.session_id)
        se.session_id,
        se.event_name AS exit_event
    FROM sessionized_events se
    JOIN abandoned_sessions a USING (session_id)
    ORDER BY se.session_id, se.event_seq_in_session DESC
),

recovery AS (
    SELECT
        a.session_id,
        EXISTS (
            SELECT 1
            FROM user_events e
            WHERE e.user_id = a.user_id
              AND e.event_name = 'complete_purchase'
              AND e.event_timestamp >  a.session_end
              AND e.event_timestamp <= a.session_end + INTERVAL '7 days'
        ) AS recovered_within_7d
    FROM abandoned_sessions a
)

SELECT
    l.exit_event,
    COUNT(*)                                                                AS abandoned_sessions,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)                      AS pct_of_cart_abandonments,
    ROUND(100.0 * AVG(CASE WHEN r.recovered_within_7d THEN 1 ELSE 0 END), 2) AS pct_recovered_within_7d
FROM last_events l
JOIN recovery r USING (session_id)
GROUP BY l.exit_event
ORDER BY abandoned_sessions DESC;


-- ---------------------------------------------------------------------------
-- C. Shipping-cost screen: what share of sessions that reach it end without a
--    purchase, by platform
-- ---------------------------------------------------------------------------
WITH shipping_sessions AS (
    SELECT
        session_id,
        MIN(platform)                              AS platform,
        BOOL_OR(event_name = 'complete_purchase')  AS has_purchase
    FROM sessionized_events
    GROUP BY session_id
    HAVING BOOL_OR(event_name = 'view_shipping_costs')
)

SELECT
    platform,
    COUNT(*)                                                               AS sessions_reaching_shipping,
    SUM(CASE WHEN has_purchase THEN 0 ELSE 1 END)                          AS left_without_buying,
    ROUND(100.0 * AVG(CASE WHEN has_purchase THEN 0 ELSE 1 END), 2)        AS shipping_exit_rate_pct
FROM shipping_sessions
GROUP BY platform
ORDER BY shipping_exit_rate_pct DESC;
