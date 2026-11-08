-- =============================================================================
-- tests/assertions.sql
-- Data-quality and logic checks. Each block raises an exception on failure, so
-- run_all.sh (psql -v ON_ERROR_STOP=1) stops with a non-zero exit code.
-- =============================================================================

-- 1. Sessionization keeps every event exactly once.
DO $$
DECLARE raw_n BIGINT; sess_n BIGINT; distinct_n BIGINT;
BEGIN
    SELECT COUNT(*) INTO raw_n FROM user_events;
    SELECT COUNT(*), COUNT(DISTINCT event_id) INTO sess_n, distinct_n FROM sessionized_events;
    IF raw_n <> sess_n OR sess_n <> distinct_n THEN
        RAISE EXCEPTION 'FAIL: sessionized_events has % rows (% distinct) vs % raw events',
                        sess_n, distinct_n, raw_n;
    END IF;
    RAISE NOTICE 'PASS: sessionization preserves all % events', raw_n;
END $$;

-- 2. No gap inside a session exceeds 30 minutes, and every session start
--    is either the user's first event or follows a gap of more than 30 minutes.
DO $$
DECLARE bad_inside BIGINT; bad_start BIGINT;
BEGIN
    WITH gaps AS (
        SELECT
            is_session_start,
            event_timestamp - LAG(event_timestamp) OVER (
                PARTITION BY user_id ORDER BY event_timestamp, event_id) AS gap
        FROM sessionized_events
    )
    SELECT
        COUNT(*) FILTER (WHERE NOT is_session_start AND gap > INTERVAL '30 minutes'),
        COUNT(*) FILTER (WHERE is_session_start AND gap IS NOT NULL
                               AND gap <= INTERVAL '30 minutes')
    INTO bad_inside, bad_start
    FROM gaps;
    IF bad_inside > 0 OR bad_start > 0 THEN
        RAISE EXCEPTION 'FAIL: % in-session gaps over 30 min, % session starts without a 30-min gap',
                        bad_inside, bad_start;
    END IF;
    RAISE NOTICE 'PASS: session boundaries match the 30-minute rule';
END $$;

-- 3. Event sequence numbers within each session run 1..n with no gaps.
DO $$
DECLARE bad BIGINT;
BEGIN
    SELECT COUNT(*) INTO bad
    FROM (
        SELECT session_id
        FROM sessionized_events
        GROUP BY session_id
        HAVING MIN(event_seq_in_session) <> 1
            OR MAX(event_seq_in_session) <> COUNT(*)
    ) s;
    IF bad > 0 THEN
        RAISE EXCEPTION 'FAIL: % sessions have non-contiguous event sequences', bad;
    END IF;
    RAISE NOTICE 'PASS: in-session event sequences are contiguous';
END $$;

-- 4. Session ids are deterministic: two evaluations of the view agree.
--    (Guards against dropping the event_id tiebreaker.)
DO $$
DECLARE mismatches BIGINT;
BEGIN
    SELECT COUNT(*) INTO mismatches
    FROM sessionized_events a
    JOIN sessionized_events b USING (event_id)
    WHERE a.session_id <> b.session_id
       OR a.event_seq_in_session <> b.event_seq_in_session;
    IF mismatches > 0 THEN
        RAISE EXCEPTION 'FAIL: % events got different session positions across evaluations', mismatches;
    END IF;
    RAISE NOTICE 'PASS: session assignment is deterministic';
END $$;

-- 5. The chained funnel never grows from one step to the next
--    (lifetime version, no window, the strictest case).
DO $$
DECLARE s1 BIGINT; s2 BIGINT; s3 BIGINT; s4 BIGINT;
BEGIN
    WITH a AS (
        SELECT user_id, MIN(event_timestamp) AS t1
        FROM user_events WHERE event_name = 'sign_up' GROUP BY user_id
    ), b AS (
        SELECT a.user_id, MIN(e.event_timestamp) AS t2
        FROM a LEFT JOIN user_events e
          ON e.user_id = a.user_id AND e.event_name = 'view_catalog' AND e.event_timestamp >= a.t1
        GROUP BY a.user_id
    ), c AS (
        SELECT b.user_id, MIN(e.event_timestamp) AS t3
        FROM b LEFT JOIN user_events e
          ON e.user_id = b.user_id AND e.event_name = 'add_to_cart' AND e.event_timestamp >= b.t2
        GROUP BY b.user_id
    ), d AS (
        SELECT c.user_id, MIN(e.event_timestamp) AS t4
        FROM c LEFT JOIN user_events e
          ON e.user_id = c.user_id AND e.event_name = 'complete_purchase' AND e.event_timestamp >= c.t3
        GROUP BY c.user_id
    )
    SELECT (SELECT COUNT(*) FROM a), (SELECT COUNT(t2) FROM b),
           (SELECT COUNT(t3) FROM c), (SELECT COUNT(t4) FROM d)
    INTO s1, s2, s3, s4;
    IF NOT (s1 >= s2 AND s2 >= s3 AND s3 >= s4) THEN
        RAISE EXCEPTION 'FAIL: funnel is not monotonic: % / % / % / %', s1, s2, s3, s4;
    END IF;
    RAISE NOTICE 'PASS: chained funnel is monotonic (% > % > % > %)', s1, s2, s3, s4;
END $$;

-- 6. Every user has exactly one sign_up event and nothing before signup
--    except pre-signup browsing (view_catalog / view_product).
DO $$
DECLARE multi BIGINT; bad_pre BIGINT;
BEGIN
    SELECT COUNT(*) INTO multi FROM (
        SELECT user_id FROM user_events WHERE event_name = 'sign_up'
        GROUP BY user_id HAVING COUNT(*) > 1
    ) x;
    SELECT COUNT(*) INTO bad_pre
    FROM user_events e
    JOIN (SELECT user_id, MIN(event_timestamp) AS signup_at
          FROM user_events WHERE event_name = 'sign_up' GROUP BY user_id) s USING (user_id)
    WHERE e.event_timestamp < s.signup_at
      AND e.event_name NOT IN ('view_catalog', 'view_product');
    IF multi > 0 OR bad_pre > 0 THEN
        RAISE EXCEPTION 'FAIL: % users with multiple signups, % unexpected pre-signup events', multi, bad_pre;
    END IF;
    RAISE NOTICE 'PASS: signup events are clean';
END $$;
