-- =============================================================================
-- 04_retention_feature_adoption.sql
-- Module 3: Early feature adoption vs. Day-30 retention
--
-- Definitions
--   Day-1 adoption : the user did the action in [signup, signup + 24h)
--   Retained       : the user had ANY event in [signup + 30d, signup + 37d)
--   Cohort         : users who signed up at least 37 days before the end of the
--                    data. Anyone more recent can't have reached the retention
--                    window yet; including them would count them as churned and
--                    drag every retention rate down.
--
-- All windows are half-open [start, end) so no event falls in two windows.
--
-- Four result sets:
--   A. Retention lift per feature (adopters vs. non-adopters) with a
--      two-proportion z-test
--   B. Dose-response: retention by number of day-1 features adopted
--   C. Full combination matrix (the original 2x2x2 view), small cells flagged
--   D. Confounding check: lift per feature WITHIN tiers of day-1 activity
--
-- Caution: this is observational data. A lift here shows association, not
-- cause. Result set D is there to separate features that hold up once you
-- account for how active a user was on day 1 from ones that don't.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Shared user-level table, built once and reused by all four result sets.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS tmp_user_retention;

CREATE TEMP TABLE tmp_user_retention AS
WITH data_bounds AS (
    SELECT MAX(event_timestamp) AS data_end FROM user_events
),

user_cohort AS (
    SELECT
        e.user_id,
        MIN(e.event_timestamp) AS signup_at
    FROM user_events e
    WHERE e.event_name = 'sign_up'
    GROUP BY e.user_id
    HAVING MIN(e.event_timestamp) + INTERVAL '37 days' <= (SELECT data_end FROM data_bounds)
),

day1_activity AS (
    SELECT
        c.user_id,
        MAX(CASE WHEN e.event_name = 'profile_setup'     THEN 1 ELSE 0 END) AS did_profile_setup,
        MAX(CASE WHEN e.event_name = 'use_search_filter' THEN 1 ELSE 0 END) AS did_search_filter,
        MAX(CASE WHEN e.event_name = 'invite_friend'     THEN 1 ELSE 0 END) AS did_invite_friend,
        COUNT(CASE WHEN e.event_name NOT IN ('sign_up', 'profile_setup',
                                             'use_search_filter', 'invite_friend')
                   THEN 1 END)                                              AS day1_other_events
    FROM user_cohort c
    LEFT JOIN user_events e
           ON e.user_id = c.user_id
          AND e.event_timestamp >= c.signup_at
          AND e.event_timestamp <  c.signup_at + INTERVAL '24 hours'
    GROUP BY c.user_id
),

retention AS (
    SELECT
        c.user_id,
        CASE WHEN COUNT(e.event_id) > 0 THEN 1 ELSE 0 END AS is_retained_d30
    FROM user_cohort c
    LEFT JOIN user_events e
           ON e.user_id = c.user_id
          AND e.event_timestamp >= c.signup_at + INTERVAL '30 days'
          AND e.event_timestamp <  c.signup_at + INTERVAL '37 days'
    GROUP BY c.user_id
)

SELECT
    d.user_id,
    d.did_profile_setup,
    d.did_search_filter,
    d.did_invite_friend,
    d.day1_other_events,
    -- Activity tier from day-1 events that are NOT the features being tested,
    -- so the tier isn't mechanically tied to adoption.
    NTILE(3) OVER (ORDER BY d.day1_other_events, d.user_id) AS day1_activity_tier,
    r.is_retained_d30
FROM day1_activity d
JOIN retention r USING (user_id);


-- ---------------------------------------------------------------------------
-- A. Retention lift per feature, with a two-proportion z-test
--    |z| > 1.96 is significant at the 5% level (two-sided).
-- ---------------------------------------------------------------------------
WITH long_format AS (
    SELECT u.user_id, u.is_retained_d30, f.feature, f.adopted
    FROM tmp_user_retention u
    CROSS JOIN LATERAL (
        VALUES ('profile_setup',     u.did_profile_setup),
               ('use_search_filter', u.did_search_filter),
               ('invite_friend',     u.did_invite_friend)
    ) AS f(feature, adopted)
),

feature_stats AS (
    SELECT
        feature,
        COUNT(*) FILTER (WHERE adopted = 1)                                AS n_adopters,
        AVG(is_retained_d30::numeric) FILTER (WHERE adopted = 1)           AS p_adopters,
        COUNT(*) FILTER (WHERE adopted = 0)                                AS n_non_adopters,
        AVG(is_retained_d30::numeric) FILTER (WHERE adopted = 0)           AS p_non_adopters,
        AVG(is_retained_d30::numeric)                                      AS p_pooled
    FROM long_format
    GROUP BY feature
)

SELECT
    feature,
    n_adopters,
    ROUND(100 * p_adopters, 2)                                AS retention_adopters_pct,
    n_non_adopters,
    ROUND(100 * p_non_adopters, 2)                            AS retention_non_adopters_pct,
    ROUND(100 * (p_adopters - p_non_adopters), 2)             AS lift_pp,
    ROUND(p_adopters / NULLIF(p_non_adopters, 0), 2)          AS lift_ratio,
    ROUND(
        (p_adopters - p_non_adopters)
        / NULLIF(SQRT(p_pooled * (1 - p_pooled)
                      * (1.0 / n_adopters + 1.0 / n_non_adopters)), 0)
    , 2)                                                      AS z_score
FROM feature_stats
ORDER BY lift_pp DESC;


-- ---------------------------------------------------------------------------
-- B. Dose-response: retention by number of day-1 features adopted
-- ---------------------------------------------------------------------------
SELECT
    did_profile_setup + did_search_filter + did_invite_friend   AS features_adopted_day1,
    COUNT(*)                                                    AS users,
    SUM(is_retained_d30)                                        AS retained_users,
    ROUND(100.0 * AVG(is_retained_d30), 2)                      AS retention_pct
FROM tmp_user_retention
GROUP BY 1
ORDER BY 1;


-- ---------------------------------------------------------------------------
-- C. Full combination matrix. Cells under 100 users are flagged: their rates
--    move a lot from sample noise alone.
-- ---------------------------------------------------------------------------
SELECT
    did_profile_setup,
    did_search_filter,
    did_invite_friend,
    COUNT(*)                                                    AS users,
    SUM(is_retained_d30)                                        AS retained_users,
    ROUND(100.0 * AVG(is_retained_d30), 2)                      AS retention_pct,
    CASE WHEN COUNT(*) < 100 THEN 'small sample' ELSE '' END    AS note
FROM tmp_user_retention
GROUP BY did_profile_setup, did_search_filter, did_invite_friend
ORDER BY users DESC;


-- ---------------------------------------------------------------------------
-- D. Confounding check: does each feature's lift survive inside tiers of
--    day-1 activity? A feature whose lift collapses within tiers was mostly
--    a marker of engaged users, not a driver of retention.
-- ---------------------------------------------------------------------------
WITH long_format AS (
    SELECT u.day1_activity_tier, u.is_retained_d30, f.feature, f.adopted
    FROM tmp_user_retention u
    CROSS JOIN LATERAL (
        VALUES ('profile_setup',     u.did_profile_setup),
               ('use_search_filter', u.did_search_filter),
               ('invite_friend',     u.did_invite_friend)
    ) AS f(feature, adopted)
),

tier_stats AS (
    SELECT
        feature,
        day1_activity_tier,
        COUNT(*) FILTER (WHERE adopted = 1)                         AS n_adopters,
        AVG(is_retained_d30::numeric) FILTER (WHERE adopted = 1)    AS p_adopters,
        COUNT(*) FILTER (WHERE adopted = 0)                         AS n_non_adopters,
        AVG(is_retained_d30::numeric) FILTER (WHERE adopted = 0)    AS p_non_adopters
    FROM long_format
    GROUP BY feature, day1_activity_tier
),

overall AS (
    SELECT
        feature,
        100 * (AVG(is_retained_d30::numeric) FILTER (WHERE adopted = 1)
             - AVG(is_retained_d30::numeric) FILTER (WHERE adopted = 0)) AS raw_lift_pp
    FROM long_format
    GROUP BY feature
)

SELECT
    t.feature,
    ROUND(o.raw_lift_pp, 2)                                                    AS raw_lift_pp,
    ROUND(MAX(100 * (t.p_adopters - t.p_non_adopters)) FILTER (WHERE t.day1_activity_tier = 1), 2)
                                                                               AS lift_low_activity_pp,
    ROUND(MAX(100 * (t.p_adopters - t.p_non_adopters)) FILTER (WHERE t.day1_activity_tier = 2), 2)
                                                                               AS lift_mid_activity_pp,
    ROUND(MAX(100 * (t.p_adopters - t.p_non_adopters)) FILTER (WHERE t.day1_activity_tier = 3), 2)
                                                                               AS lift_high_activity_pp,
    -- Weighted average of within-tier lifts (weights = tier size).
    ROUND(
        SUM(100 * (t.p_adopters - t.p_non_adopters) * (t.n_adopters + t.n_non_adopters))
        / SUM(t.n_adopters + t.n_non_adopters)
    , 2)                                                                       AS activity_adjusted_lift_pp,
    MIN(t.n_adopters)                                                          AS smallest_adopter_cell
FROM tier_stats t
JOIN overall o USING (feature)
GROUP BY t.feature, o.raw_lift_pp
ORDER BY activity_adjusted_lift_pp DESC;
