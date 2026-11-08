-- Load the generated CSV. Run from the repository root (run_all.sh does this).
\copy user_events FROM 'data/user_events.csv' WITH (FORMAT csv, HEADER true)
ANALYZE user_events;
