-- Module 3: 30-Day Retention & "Aha Moment" Behavioral Lift Analysis
WITH user_cohort AS (
    SELECT 
        user_id,
        MIN(event_timestamp) AS signup_timestamp,
        MIN(event_timestamp) + INTERVAL '7 days' AS day_7_window,
        MIN(event_timestamp) + INTERVAL '30 days' AS day_30_window
    FROM product_analytics.user_events
    WHERE event_name = 'sign_up'
    GROUP BY user_id
),

early_feature_adoption AS (
    SELECT 
        uc.user_id,
        MAX(CASE WHEN e.event_name = 'use_search_filter' AND e.event_timestamp <= uc.day_7_window THEN 1 ELSE 0 END) AS used_search_d7,
        MAX(CASE WHEN e.event_name = 'invite_friend' AND e.event_timestamp <= uc.day_7_window THEN 1 ELSE 0 END) AS invited_friend_d7
    FROM user_cohort uc
    LEFT JOIN product_analytics.user_events e 
        ON uc.user_id = e.user_id
    GROUP BY uc.user_id
),

day_30_retention AS (
    SELECT 
        uc.user_id,
        MAX(CASE WHEN e.event_timestamp BETWEEN uc.day_30_window - INTERVAL '3 days' AND uc.day_30_window + INTERVAL '3 days' THEN 1 ELSE 0 END) AS retained_d30
    FROM user_cohort uc
    LEFT JOIN product_analytics.user_events e 
        ON uc.user_id = e.user_id AND e.event_name != 'sign_up'
    GROUP BY uc.user_id
)

SELECT 
    efa.used_search_d7,
    efa.invited_friend_d7,
    COUNT(uc.user_id) AS user_count,
    SUM(r.retained_d30) AS retained_users,
    ROUND(100.0 * SUM(r.retained_d30) / COUNT(uc.user_id), 2) AS d30_retention_rate
FROM user_cohort uc
JOIN early_feature_adoption efa ON uc.user_id = efa.user_id
JOIN day_30_retention r ON uc.user_id = r.user_id
GROUP BY efa.used_search_d7, efa.invited_friend_d7
ORDER BY d30_retention_rate DESC;