#!/usr/bin/env bash
# Build the dataset, load it, run every module and the tests.
# Uses the standard libpq environment variables (PGHOST, PGPORT, PGUSER,
# PGDATABASE, PGPASSWORD). Example:
#   createdb analytics && PGDATABASE=analytics ./run_all.sh
set -euo pipefail
cd "$(dirname "$0")"

PSQL=(psql -X -q -v ON_ERROR_STOP=1 -P footer=off)

echo "==> Generating synthetic events"
python3 data/generate_events.py --users 6000 --seed 42 --out data/user_events.csv

echo "==> Creating schema and loading data"
"${PSQL[@]}" -f sql/00_schema.sql 2>/dev/null
"${PSQL[@]}" -f sql/00_load.sql
"${PSQL[@]}" -f sql/01_sessionized_events.sql

mkdir -p results
for module in 02_funnel_conversion 03_exit_path_analysis 04_retention_feature_adoption; do
    echo "==> Running ${module}"
    "${PSQL[@]}" -f "sql/${module}.sql" 2>/dev/null > "results/${module}.txt"
done

echo "==> Running assertions"
"${PSQL[@]}" -f sql/tests/assertions.sql

echo "==> Done. Results are in results/"
