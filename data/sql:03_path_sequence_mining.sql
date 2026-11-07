-- Module 2: Aggregate Event Path Trajectories for Non-Converting Sessions
WITH session_lags AS (
    SELECT 
        user_id,
        event_name,
        event_timestamp,
        LAG(event_timestamp) OVER (PARTITION BY user_id ORDER BY event_timestamp) AS prev_ts
    FROM product_analytics.user_events
),

sessionized_events AS (
    SELECT 
        user_id,
        event_name,
        event_timestamp,
        user_id || '_s' || SUM(CASE WHEN prev_ts IS NULL OR EXTRACT(EPOCH FROM (event_timestamp - prev_ts)) > 1800 THEN 1 ELSE 0 END) 
            OVER (PARTITION BY user_id ORDER BY event_timestamp) AS session_id
    FROM session_lags
),

ordered_session_events AS (
    SELECT 
        user_id,
        session_id,
        event_name,
        event_timestamp,
        ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY event_timestamp) AS event_seq,
        MAX(CASE WHEN event_name = 'complete_purchase' THEN 1 ELSE 0 END) OVER (PARTITION BY session_id) AS session_converted
    FROM sessionized_events
),

session_paths AS (
    SELECT 
        session_id,
        user_id,
        STRING_AGG(event_name, ' -> ' ORDER BY event_seq) AS full_event_path,
        COUNT(*) AS path_length
    FROM ordered_session_events
    WHERE session_converted = 0
    GROUP BY session_id, user_id
)

SELECT 
    full_event_path,
    COUNT(*) AS abandoned_session_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_total_abandonments
FROM session_paths
WHERE path_length >= 2
GROUP BY full_event_path
ORDER BY abandoned_session_count DESC
LIMIT 5;