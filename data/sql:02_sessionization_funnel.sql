-- Module 1: Sessionization via 30-Minute Inactivity Window & Funnel Aggregation
WITH event_lags AS (
    SELECT 
        event_id,
        user_id,
        event_name,
        event_timestamp,
        platform,
        LAG(event_timestamp) OVER (
            PARTITION BY user_id 
            ORDER BY event_timestamp
        ) AS prev_event_timestamp
    FROM product_analytics.user_events
),

session_flags AS (
    SELECT 
        *,
        CASE 
            WHEN prev_event_timestamp IS NULL THEN 1
            WHEN EXTRACT(EPOCH FROM (event_timestamp - prev_event_timestamp)) > 1800 THEN 1
            ELSE 0 
        END AS is_new_session
    FROM event_lags
),

session_indexing AS (
    SELECT 
        event_id,
        user_id,
        event_name,
        event_timestamp,
        platform,
        user_id || '_s' || SUM(is_new_session) OVER (
            PARTITION BY user_id 
            ORDER BY event_timestamp
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS session_id
    FROM session_flags
),

funnel_user_steps AS (
    SELECT 
        user_id,
        MIN(CASE WHEN event_name = 'sign_up' THEN event_timestamp END) AS step1_signup_at,
        MIN(CASE WHEN event_name = 'view_catalog' THEN event_timestamp END) AS step2_catalog_at,
        MIN(CASE WHEN event_name = 'add_to_cart' THEN event_timestamp END) AS step3_cart_at,
        MIN(CASE WHEN event_name = 'complete_purchase' THEN event_timestamp END) AS step4_purchase_at
    FROM session_indexing
    GROUP BY user_id
)

SELECT 
    COUNT(step1_signup_at) AS total_signups,
    
    COUNT(CASE WHEN step2_catalog_at >= step1_signup_at THEN user_id END) AS step2_catalog_users,
    ROUND(100.0 * COUNT(CASE WHEN step2_catalog_at >= step1_signup_at THEN user_id END) 
        / NULLIF(COUNT(step1_signup_at), 0), 2) AS signup_to_catalog_pct,
        
    COUNT(CASE WHEN step3_cart_at >= step2_catalog_at THEN user_id END) AS step3_cart_users,
    ROUND(100.0 * COUNT(CASE WHEN step3_cart_at >= step2_catalog_at THEN user_id END) 
        / NULLIF(COUNT(CASE WHEN step2_catalog_at >= step1_signup_at THEN user_id END), 0), 2) AS catalog_to_cart_pct,
        
    COUNT(CASE WHEN step4_purchase_at >= step3_cart_at THEN user_id END) AS step4_purchase_users,
    ROUND(100.0 * COUNT(CASE WHEN step4_purchase_at >= step3_cart_at THEN user_id END) 
        / NULLIF(COUNT(CASE WHEN step3_cart_at >= step2_catalog_at THEN user_id END), 0), 2) AS cart_to_purchase_pct,
        
    ROUND(100.0 * COUNT(CASE WHEN step4_purchase_at >= step3_cart_at THEN user_id END) 
        / NULLIF(COUNT(step1_signup_at), 0), 2) AS overall_conversion_rate
FROM funnel_user_steps;