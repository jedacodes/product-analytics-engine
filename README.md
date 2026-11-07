# Product Analytics & User Journey Pathing Engine

A high-performance PostgreSQL and Python analytics engine designed to extract funnel conversion metrics, reconstruct 30-minute user session trajectories, mine abandonment paths, and compute 30-day behavioral retention lift.

## Project Structure
```text
product-analytics-engine/
├── data/
│   ├── seed_script.py            # Synthetic telemetry data generation script
│   └── raw_events.csv            # Generated clickstream dataset (13,986 rows)
├── sql/
│   ├── 01_schema_setup.sql       # DDL schema definition & indexes
│   ├── 02_sessionization_funnel.sql # Window functions for 30-min sessionization & funnel
│   ├── 03_path_sequence_mining.sql # STRING_AGG path sequence mining for drop-offs
│   └── 04_retention_aha_matrix.sql # Day-7 feature adoption vs. Day-30 retention lift
└── docs/
    └── executive_memo.md         # Product strategy memo & recommendations
