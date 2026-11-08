# Product Analytics & User Journey Pathing Engine

A SQL analytics project that answers three product questions from raw event telemetry:

1. **Where do users drop out of the purchase funnel?**
2. **What is the last thing users do before they abandon a cart?**
3. **Which day-1 behaviours are associated with users still being around a month later, and which of those associations hold up?**

Everything runs end to end on PostgreSQL from a single script, against a seeded synthetic dataset of **6,000 users and 334,078 events** (May to September 2026). Because the data is synthetic, the behaviours it contains are known in advance, which means the analysis can be checked against the truth. See [Did the analysis find what was planted?](#did-the-analysis-find-what-was-planted).

---

## Executive summary

| Question | Finding |
|---|---|
| Highest-friction funnel step | **Cart → purchase**: only 57.2% of users who add to cart buy within 14 days of signup. Catalog → cart loses more users in absolute terms (1,785 vs 1,617), but checkout leaks at a higher rate. |
| Where checkout breaks | **The shipping-cost screen.** 56.7% of abandoned carts end there. |
| Platform gap | **Android checkout converts at 45.1%** vs. 61.0% on web and iOS combined. Android users who reach the shipping screen leave without buying 62.9% of the time, vs. 42 to 44% elsewhere. Closing that gap would lift overall 14-day conversion from **38.4% to about 41.0%** (+144 purchasers in this cohort). |
| "Aha moment" candidate | **Using the search filter on day 1.** Day-30 retention is 47.9% for users who do it vs. 25.7% for those who don't (+22.3 pp, z = 15.7). The gap stays at +19.6 pp after adjusting for how active users were on day 1. |
| Feature that looks good but isn't | **Inviting a friend.** It shows a +6.6 pp raw lift and stays positive after adjustment, yet in this simulation it has **no causal effect at all**. The lift is leftover confounding from engaged users being the ones who invite. |

**Recommended next steps:** prioritise an Android checkout fix and show shipping costs earlier in the journey (on the product or cart page); then run a controlled experiment that prompts new users toward the search filter, rather than treating the observed lift as proof.

---

## Quickstart

Requirements: Python 3.8+ (standard library only) and PostgreSQL 14+.

```bash
createdb analytics
PGDATABASE=analytics bash run_all.sh
```

This generates the data, loads it, builds the session layer, runs the three modules (writing to `results/`), and runs the test suite. The full run takes about 12 seconds on a laptop. The generator is seeded, so you will get the exact numbers in this README.

---

## Repository layout

```
├── data/
│   └── generate_events.py            # seeded synthetic data generator (stdlib only)
├── sql/
│   ├── 00_schema.sql                 # user_events table + indexes
│   ├── 00_load.sql                   # \copy loader
│   ├── 01_sessionized_events.sql     # shared session layer (view)
│   ├── 02_funnel_conversion.sql      # Module 1: chained funnel, overall + by platform
│   ├── 03_exit_path_analysis.sql     # Module 2: exit paths, exit events, recovery
│   ├── 04_retention_feature_adoption.sql  # Module 3: lift, z-tests, confounding check
│   └── tests/
│       └── assertions.sql            # data-quality and logic checks
├── docs/
│   └── executive_memo.md             # one-page memo for stakeholders
├── results/                          # query output from the last run
└── run_all.sh
```

---

## Data model

```sql
CREATE TABLE user_events (
    event_id        VARCHAR(50) PRIMARY KEY,
    user_id         VARCHAR(50) NOT NULL,
    event_name      VARCHAR(50) NOT NULL,
    event_timestamp TIMESTAMP   NOT NULL,   -- UTC
    platform        VARCHAR(20) NOT NULL    -- web | ios | android
);
```

Event vocabulary: `sign_up`, `profile_setup`, `use_search_filter`, `invite_friend`, `app_open`, `view_catalog`, `view_product`, `add_to_cart`, `view_cart`, `apply_coupon`, `begin_checkout`, `view_shipping_costs`, `complete_purchase`.

The generator deliberately includes awkward but realistic data: about a quarter of users browse before signing up, and some events share a timestamp to the second.

---

## Methodology

### Sessionization (`01_sessionized_events.sql`)

A new session starts on a user's first event or after more than 30 minutes of inactivity. This logic lives in **one view** that every module reads, so the session definition can't drift between analyses. Every window function orders by `event_timestamp, event_id`; without the `event_id` tiebreaker, events with identical timestamps get a different order on each run. The dataset produces **88,138 sessions** averaging 3.8 events each.

### Module 1: Funnel conversion (`02_funnel_conversion.sql`)

`sign_up → view_catalog → add_to_cart → complete_purchase`

- **Chained steps.** Each step is the first qualifying event *after the previous step was completed*. If a user never reaches a step, every later step is empty for them too, so the funnel can only narrow.
- **14-day conversion window**, measured from signup.
- **Only users who signed up at least 14 days before the data ends** are included. Anyone more recent hasn't had the full window to convert.

### Module 2: Exit paths (`03_exit_path_analysis.sql`)

- An **abandoned cart session** contains `add_to_cart` but no `complete_purchase`. Sessions where the user only browsed are excluded, because they never showed purchase intent.
- The analysis looks at the **last three events** before the user left, not the whole session. Whole-session paths are nearly unique for long sessions and never rank; the tail of the session is what explains the exit.
- It also measures **recovery**: how often the user came back and bought within 7 days.

### Module 3: Feature adoption and retention (`04_retention_feature_adoption.sql`)

- **Day-1 adoption:** the action happened in `[signup, signup + 24h)`.
- **Retained:** any event in `[signup + 30d, signup + 37d)`.
- **Cohort:** users who signed up at least 37 days before the data ends (4,674 of 6,000). Including newer users would count them as churned simply because their Day 30 hasn't arrived.
- **Per-feature lift** (adopters vs. non-adopters) with a two-proportion z-test.
- **Dose-response:** retention by number of features adopted.
- **Confounding check:** lift recalculated within thirds of day-1 activity (counted from events that are *not* the features being tested). A feature whose lift shrinks within those groups was partly a marker of engaged users, not a driver.

---

## Results

### Funnel (14-day window, 5,620 users)

| Step | Users | % of previous step | % of signups |
|---|---:|---:|---:|
| sign_up | 5,620 | | 100.0 |
| view_catalog | 5,562 | 99.0 | 99.0 |
| add_to_cart | 3,777 | 67.9 | 67.2 |
| complete_purchase | 2,160 | **57.2** | 38.4 |

| Platform | Signups | Catalog → cart | Cart → purchase | Overall |
|---|---:|---:|---:|---:|
| iOS | 1,703 | 68.5% | 61.1% | 41.5% |
| Web | 2,551 | 68.0% | 60.9% | 41.0% |
| Android | 1,366 | 67.1% | **45.1%** | **29.9%** |

Browsing behaviour is nearly identical across platforms; the Android gap appears entirely at checkout.

### Exit paths (abandoned cart sessions)

| Last three events before exit | Share |
|---|---:|
| view_cart > begin_checkout > view_shipping_costs | 52.4% |
| view_product > add_to_cart > view_cart | 35.0% |
| add_to_cart > view_cart > apply_coupon | 7.0% |
| apply_coupon > begin_checkout > view_shipping_costs | 4.1% |

| Final event | Share of abandonments | Recovered within 7 days |
|---|---:|---:|
| view_shipping_costs | 56.7% | 25.8% |
| view_cart | 35.0% | 26.5% |
| apply_coupon | 7.0% | 28.2% |

Only about a quarter of abandoners come back and buy within a week, and that rate barely changes with where they left. Most abandoned carts are lost, not deferred.

| Platform | Sessions reaching shipping costs | Left without buying |
|---|---:|---:|
| Android | 3,499 | **62.9%** |
| iOS | 4,185 | 43.9% |
| Web | 6,419 | 42.3% |

### Retention (4,674 users, overall Day-30 retention 34.6%)

| Day-1 feature | Adopters | Retained (adopters) | Retained (others) | Lift | z | Lift after adjusting for day-1 activity |
|---|---:|---:|---:|---:|---:|---:|
| use_search_filter | 1,880 | 47.9% | 25.7% | +22.3 pp | 15.7 | **+19.6 pp** |
| profile_setup | 1,892 | 40.3% | 30.8% | +9.5 pp | 6.7 | +8.2 pp |
| invite_friend | 341 | 40.8% | 34.1% | +6.6 pp | 2.5 | +4.6 pp |

| Features adopted on day 1 | Users | Day-30 retention |
|---:|---:|---:|
| 0 | 1,640 | 21.5% |
| 1 | 2,044 | 37.9% |
| 2 | 901 | 49.2% |
| 3 | 89 | 52.8% |

The full 2×2×2 combination matrix is in `results/04_retention_feature_adoption.txt`. Four of its eight cells have fewer than 100 users and are flagged in the output.

---

## Did the analysis find what was planted?

The generator (`data/generate_events.py`) builds these behaviours in. Checking the SQL against them is the closest thing to ground truth a portfolio project can have.

| Planted in the data | What the SQL found | Verdict |
|---|---|---|
| Android purchase rate after the shipping screen is 36% vs. 55 to 58% elsewhere | Android shipping-screen exit rate 62.9% vs. 42 to 44% | ✅ Recovered |
| Checkout leaks at the shipping-cost screen | Top exit event and top exit path | ✅ Recovered |
| Search filter extends a user's active life by about 22 days on average | Largest lift, holds after adjustment | ✅ Recovered |
| Profile setup extends active life by about 5 days | Smaller lift, holds after adjustment | ✅ Recovered |
| **Inviting a friend has zero effect** | +6.6 pp raw, **+4.6 pp after adjustment** | ⚠️ Partially misleading |

The last row is the most useful result in the project. Inviting a friend has no effect in the simulation, but the engaged users who invite also retain better. Adjusting for day-1 activity removes only part of that, because day-1 event counts are an imperfect stand-in for engagement. In the most active third of users, the invite lift falls to +0.7 pp, which is the clue. In a real product, nobody would have the ground-truth column. This is why observational lift should rank candidates for experiments, not replace them.

---

## Why the original approach was rewritten

This project started from a first draft that used `MIN()` per event type for the funnel and counted every signup in the retention cohort. Running that draft against the same data shows how much those choices distort the answer:

| Metric | First draft | Corrected | What went wrong |
|---|---:|---:|---|
| Signup → catalog | 74.8% | 99.0% | 1,458 users browsed before signing up. `MIN(view_catalog)` returned the pre-signup visit, so they failed the "after signup" check even though they browsed again later. |
| Catalog → cart | 99.8% | 67.9% | Each step was only compared with the step before it, so users who had failed step 2 were still counted at step 3. |
| Day-30 retention | 28.5% | 34.6% | 1,326 users who signed up too recently to reach Day 30 were counted as churned. |

The draft placed the biggest drop-off at the catalog step, which is the wrong place. A team acting on it would have redesigned the catalog and left checkout alone. (The draft numbers use lifetime conversion, so they aren't directly comparable with the 14-day figures above; the step-to-step pattern is the point.)

---

## Tests

`sql/tests/assertions.sql` runs at the end of `run_all.sh` and fails the build if any check fails:

- Sessionization keeps every event exactly once.
- No in-session gap exceeds 30 minutes, and every session start follows a gap of more than 30 minutes.
- Event sequence numbers in each session run 1 to n with no gaps.
- Session assignment is deterministic across evaluations.
- The chained funnel never grows from one step to the next.
- Each user has exactly one signup, and the only pre-signup events are browsing events.

---

## Running on Snowflake

The SQL is written for PostgreSQL. These are the changes needed for Snowflake:

| PostgreSQL | Snowflake |
|---|---|
| `ts - prev_ts > INTERVAL '30 minutes'` | `DATEDIFF('second', prev_ts, ts) > 1800` |
| `STRING_AGG(x, ' > ' ORDER BY seq)` | `LISTAGG(x, ' > ') WITHIN GROUP (ORDER BY seq)` |
| `SELECT DISTINCT ON (user_id) ... ORDER BY ...` | `QUALIFY ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY ...) = 1` |
| `BOOL_OR(cond)` | `BOOLOR_AGG(cond)` |
| `AVG(x) FILTER (WHERE cond)` | `AVG(IFF(cond, x, NULL))` |
| `CROSS JOIN LATERAL (VALUES ...)` | `UNPIVOT`, or a `UNION ALL` of the three features |
| `CREATE TEMP TABLE` | `CREATE TEMPORARY TABLE` |
| `DO $$ ... RAISE EXCEPTION $$` (tests) | Snowflake Scripting block, or dbt tests |
| `\copy` | `PUT` + `COPY INTO` from a stage |

---

## Limitations and extensions

- **Correlation, not causation.** The confounding check narrows the gap but can't close it. An A/B test of a search-filter prompt in onboarding is the proper next step.
- **Fixed thresholds.** The 30-minute session gap, 14-day conversion window and Day 30–37 retention window are conventions. A sensitivity check across alternative values would show how much the conclusions depend on them.
- **Single funnel.** The funnel is hard-coded to four steps. A generic version would read step definitions from a config table.
- **No time trend.** Cohorts could be split by signup week to show whether conversion and retention are improving.
- **Scale.** At warehouse scale, `sessionized_events` should become an incrementally built table (for example a dbt incremental model) rather than a view.
