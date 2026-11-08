-- =============================================================================
-- 00_schema.sql
-- Raw event telemetry table and the indexes the analysis modules rely on.
-- Dialect: PostgreSQL 14+
-- =============================================================================

DROP VIEW  IF EXISTS sessionized_events;
DROP TABLE IF EXISTS user_events;

CREATE TABLE user_events (
    event_id        VARCHAR(50) PRIMARY KEY,
    user_id         VARCHAR(50) NOT NULL,
    event_name      VARCHAR(50) NOT NULL,
    event_timestamp TIMESTAMP   NOT NULL,   -- stored in UTC
    platform        VARCHAR(20) NOT NULL
);

-- Every window function in this project partitions by user and orders by time.
CREATE INDEX idx_user_events_user_ts ON user_events (user_id, event_timestamp, event_id);

-- Funnel and retention steps filter on event_name.
CREATE INDEX idx_user_events_name_user ON user_events (event_name, user_id, event_timestamp);
