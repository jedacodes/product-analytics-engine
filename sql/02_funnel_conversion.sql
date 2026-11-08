-- =============================================================================
-- 02_funnel_conversion.sql
-- Module 1: Ordered funnel conversion within 14 days of signup
--   sign_up -> view_catalog -> add_to_cart -> complete_purchase
--
-- Method: a "chained" funnel. Each step is the user's first qualifying event
-- AFTER they completed the previous step and within the conversion window.
-- A user who never reached step N has a NULL there, which makes every later step
-- NULL as well, so each step is a strict subset of the one before and conversion
-- can never exceed 100%.
--
-- Why not MIN() per event type: if a user browsed the catalog before signing up,
-- MIN(view_catalog) returns the pre-signup visit and the user wrongly drops out
-- of the funnel, even if they browsed again afterwards.
--
-- Cohort: only users who signed up at least 14 days before the end of the data,
-- so everyone counted has had the full window to convert.
--
-- Two result sets:
--   A. Overall funnel, one row per step
--   B. Funnel by signup platform
-- =============================================================================

-- ---------------------------------------------------------------------------
-- A. Overall funnel
-- ---------------------------------------------------------------------------
WITH params AS (
    SELECT
        INTERVAL '14 days'          AS conversion_window,
        MAX(event_timestamp)        AS data_end
    FROM user_events
),

step1 AS (
    SELECT
        e.user_id,
        MIN(e.event_timestamp)                         AS signup_at,
        MIN(e.event_timestamp) + p.conversion_window   AS window_end
    FROM user_events e
    CROSS JOIN params p
    WHERE e.event_name = 'sign_up'
    GROUP BY e.user_id, p.conversion_window, p.data_end
    HAVING MIN(e.event_timestamp) + p.conversion_window <= p.data_end
),

step2 AS (
    SELECT s.user_id, s.window_end, MIN(e.event_timestamp) AS catalog_at
    FROM step1 s
    LEFT JOIN user_events e
           ON e.user_id = s.user_id
          AND e.event_name = 'view_catalog'
          AND e.event_timestamp >= s.signup_at
          AND e.event_timestamp <  s.window_end
    GROUP BY s.user_id, s.window_end
),

step3 AS (
    SELECT s.user_id, s.window_end, s.catalog_at, MIN(e.event_timestamp) AS cart_at
    FROM step2 s
    LEFT JOIN user_events e
           ON e.user_id = s.user_id
          AND e.event_name = 'add_to_cart'
          AND e.event_timestamp >= s.catalog_at        -- NULL catalog_at matches nothing
          AND e.event_timestamp <  s.window_end
    GROUP BY s.user_id, s.window_end, s.catalog_at
),

user_funnel AS (
    SELECT s.user_id, s.catalog_at, s.cart_at, MIN(e.event_timestamp) AS purchase_at
    FROM step3 s
    LEFT JOIN user_events e
           ON e.user_id = s.user_id
          AND e.event_name = 'complete_purchase'
          AND e.event_timestamp >= s.cart_at
          AND e.event_timestamp <  s.window_end
    GROUP BY s.user_id, s.catalog_at, s.cart_at
),

step_counts AS (
    SELECT 1 AS step_number, 'sign_up'           AS step_name, COUNT(*)           AS users FROM user_funnel
    UNION ALL
    SELECT 2,                'view_catalog',                   COUNT(catalog_at)           FROM user_funnel
    UNION ALL
    SELECT 3,                'add_to_cart',                    COUNT(cart_at)              FROM user_funnel
    UNION ALL
    SELECT 4,                'complete_purchase',              COUNT(purchase_at)          FROM user_funnel
)

SELECT
    step_number,
    step_name,
    users,
    LAG(users) OVER (ORDER BY step_number) - users                       AS dropped_from_prev_step,
    ROUND(100.0 * users / NULLIF(LAG(users) OVER (ORDER BY step_number), 0), 2)
                                                                         AS pct_of_prev_step,
    ROUND(100.0 * users / NULLIF(FIRST_VALUE(users) OVER (ORDER BY step_number), 0), 2)
                                                                         AS pct_of_signups
FROM step_counts
ORDER BY step_number;


-- ---------------------------------------------------------------------------
-- B. Funnel by platform (the platform the user signed up on)
-- ---------------------------------------------------------------------------
WITH params AS (
    SELECT
        INTERVAL '14 days'          AS conversion_window,
        MAX(event_timestamp)        AS data_end
    FROM user_events
),

first_signup AS (
    SELECT DISTINCT ON (user_id)
        user_id,
        event_timestamp AS signup_at,
        platform
    FROM user_events
    WHERE event_name = 'sign_up'
    ORDER BY user_id, event_timestamp, event_id
),

step1 AS (
    SELECT f.user_id, f.platform, f.signup_at, f.signup_at + p.conversion_window AS window_end
    FROM first_signup f
    CROSS JOIN params p
    WHERE f.signup_at + p.conversion_window <= p.data_end
),

step2 AS (
    SELECT s.user_id, s.platform, s.window_end, MIN(e.event_timestamp) AS catalog_at
    FROM step1 s
    LEFT JOIN user_events e
           ON e.user_id = s.user_id
          AND e.event_name = 'view_catalog'
          AND e.event_timestamp >= s.signup_at
          AND e.event_timestamp <  s.window_end
    GROUP BY s.user_id, s.platform, s.window_end
),

step3 AS (
    SELECT s.user_id, s.platform, s.window_end, s.catalog_at, MIN(e.event_timestamp) AS cart_at
    FROM step2 s
    LEFT JOIN user_events e
           ON e.user_id = s.user_id
          AND e.event_name = 'add_to_cart'
          AND e.event_timestamp >= s.catalog_at
          AND e.event_timestamp <  s.window_end
    GROUP BY s.user_id, s.platform, s.window_end, s.catalog_at
),

user_funnel AS (
    SELECT s.user_id, s.platform, s.catalog_at, s.cart_at, MIN(e.event_timestamp) AS purchase_at
    FROM step3 s
    LEFT JOIN user_events e
           ON e.user_id = s.user_id
          AND e.event_name = 'complete_purchase'
          AND e.event_timestamp >= s.cart_at
          AND e.event_timestamp <  s.window_end
    GROUP BY s.user_id, s.platform, s.catalog_at, s.cart_at
)

SELECT
    platform,
    COUNT(*)                                                             AS signups,
    COUNT(catalog_at)                                                    AS viewed_catalog,
    COUNT(cart_at)                                                       AS added_to_cart,
    COUNT(purchase_at)                                                   AS purchased,
    ROUND(100.0 * COUNT(catalog_at)  / NULLIF(COUNT(*), 0), 2)           AS signup_to_catalog_pct,
    ROUND(100.0 * COUNT(cart_at)     / NULLIF(COUNT(catalog_at), 0), 2)  AS catalog_to_cart_pct,
    ROUND(100.0 * COUNT(purchase_at) / NULLIF(COUNT(cart_at), 0), 2)     AS cart_to_purchase_pct,
    ROUND(100.0 * COUNT(purchase_at) / NULLIF(COUNT(*), 0), 2)           AS overall_conversion_pct
FROM user_funnel
GROUP BY platform
ORDER BY overall_conversion_pct DESC;
