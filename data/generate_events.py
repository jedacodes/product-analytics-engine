#!/usr/bin/env python3
"""
Synthetic event telemetry for the Product Analytics & User Journey Pathing Engine.

Standard library only (no Faker, no numpy), seeded, so every run produces the
same CSV and the same results in the README.

The generator plants a few behaviours on purpose, so the SQL has something real
to find:

  * Each user has a hidden "engagement" score. It drives how often they come
    back, how much they do on day 1, and how likely they are to try features.
  * Using the search filter on day 1 genuinely extends a user's active life.
    Profile setup helps a little. Inviting a friend has NO effect of its own;
    it only looks useful because engaged users are the ones who invite.
  * Checkout leaks at the shipping-cost screen, and Android checkout is worse
    than web and iOS.
  * About a quarter of users browse the catalog before they sign up. A naive
    MIN()-based funnel mishandles these users; the chained funnel does not.
  * Some events share a timestamp to the second, so window functions need a
    tiebreaker (event_id) to order them deterministically.

Usage:
    python3 data/generate_events.py --users 6000 --seed 42 --out data/user_events.csv
"""

import argparse
import csv
import math
import random
from datetime import datetime, timedelta

DATA_START = datetime(2026, 5, 1)
DATA_END = datetime(2026, 9, 30, 23, 59, 59)

PLATFORMS = [("web", 0.45), ("ios", 0.30), ("android", 0.25)]
PURCHASE_AFTER_SHIPPING = {"web": 0.58, "ios": 0.55, "android": 0.36}


class EventWriter:
    def __init__(self):
        self.rows = []
        self.counter = 0

    def add(self, user_id, name, ts, platform):
        if ts > DATA_END:
            return False
        self.counter += 1
        self.rows.append((f"evt_{self.counter:08d}", user_id, name,
                          ts.replace(microsecond=0), platform))
        return True


def pick_platform(rng):
    r, acc = rng.random(), 0.0
    for name, p in PLATFORMS:
        acc += p
        if r < acc:
            return name
    return PLATFORMS[-1][0]


def step(rng, ts, lo=8, hi=240):
    """Advance time inside a session (well under the 30-minute threshold)."""
    return ts + timedelta(seconds=rng.randint(lo, hi))


def browse_events(rng, w, uid, ts, platform, engagement, allow_filter=True):
    """A browsing burst: catalog, a few products, maybe the search filter."""
    w.add(uid, "view_catalog", ts, platform)
    for _ in range(1 + int(rng.random() * (1 + 4 * engagement))):
        ts = step(rng, ts)
        if allow_filter and rng.random() < 0.15:
            w.add(uid, "use_search_filter", ts, platform)
            ts = step(rng, ts)
        w.add(uid, "view_product", ts, platform)
    return ts


def cart_events(rng, w, uid, ts, platform):
    """Add to cart and walk into checkout. Returns True if it ends in a purchase."""
    ts = step(rng, ts)
    w.add(uid, "add_to_cart", ts, platform)
    # Same-second cart view on some apps: a deliberate timestamp tie.
    if rng.random() < 0.3:
        w.add(uid, "view_cart", ts, platform)
    else:
        ts = step(rng, ts, 3, 60)
        w.add(uid, "view_cart", ts, platform)

    if rng.random() < 0.22:          # leaves from the cart page
        return False
    if rng.random() < 0.12:          # tries a coupon first; some give up there
        ts = step(rng, ts)
        w.add(uid, "apply_coupon", ts, platform)
        if rng.random() < 0.45:
            return False

    ts = step(rng, ts)
    w.add(uid, "begin_checkout", ts, platform)
    ts = step(rng, ts, 5, 90)
    w.add(uid, "view_shipping_costs", ts, platform)
    if rng.random() < PURCHASE_AFTER_SHIPPING[platform]:
        ts = step(rng, ts, 20, 300)
        w.add(uid, "complete_purchase", ts, platform)
        return True
    return False


def shopping_session(rng, w, uid, ts, platform, engagement):
    ts = browse_events(rng, w, uid, ts, platform, engagement)
    if rng.random() < 0.18 + 0.30 * engagement:
        cart_events(rng, w, uid, ts, platform)


def light_session(rng, w, uid, ts, platform):
    """A quick check-in: open the app, glance at the catalog, leave."""
    w.add(uid, "app_open", ts, platform)
    if rng.random() < 0.6:
        w.add(uid, "view_catalog", step(rng, ts), platform)


def simulate_user(rng, w, n):
    uid = f"u_{n:05d}"
    platform = pick_platform(rng)
    engagement = rng.betavariate(2, 3)

    span = (DATA_END - DATA_START).total_seconds()
    signup_at = DATA_START + timedelta(seconds=rng.random() * span * 0.97)

    # 1. Anonymous browsing before signup, stitched to the user later.
    if rng.random() < 0.25:
        pre = signup_at - timedelta(hours=rng.uniform(4, 72))
        if pre >= DATA_START:
            browse_events(rng, w, uid, pre, platform, engagement, allow_filter=False)

    # 2. Signup session.
    ts = signup_at
    w.add(uid, "sign_up", ts, platform)

    did_profile = rng.random() < 0.20 + 0.50 * engagement
    did_filter = rng.random() < 0.10 + 0.55 * engagement
    did_invite = rng.random() < 0.02 + 0.22 * engagement ** 1.5

    if did_profile:
        ts = step(rng, ts, 20, 180)
        w.add(uid, "profile_setup", ts, platform)

    if rng.random() < 0.88:
        ts = step(rng, ts)
        ts = browse_events(rng, w, uid, ts, platform, engagement, allow_filter=False)
        if did_filter:
            ts = step(rng, ts)
            w.add(uid, "use_search_filter", ts, platform)
            ts = step(rng, ts)
            w.add(uid, "view_product", ts, platform)
        if rng.random() < 0.10 + 0.25 * engagement:
            cart_events(rng, w, uid, ts, platform)
    elif did_filter:
        did_filter = False  # never reached the catalog on day 1

    # 3. More day-1 sessions for engaged users (this is the "day-1 activity" signal).
    day1_extra = int(rng.random() * (1 + 4 * engagement))
    for _ in range(day1_extra):
        s = signup_at + timedelta(hours=rng.uniform(1.0, 22.0))
        shopping_session(rng, w, uid, s, platform, engagement)
    if did_invite:
        w.add(uid, "invite_friend",
              signup_at + timedelta(hours=rng.uniform(0.5, 20.0)), platform)

    # 4. Lifetime activity. Mean active life in days.
    #    Filter has a real effect; invite has none beyond engagement.
    mean_life = 6 + 55 * engagement + 22 * did_filter + 5 * did_profile
    lifetime_days = rng.expovariate(1 / mean_life)
    churn_at = signup_at + timedelta(days=lifetime_days)

    rate_per_day = 0.15 + 0.85 * engagement
    t = signup_at + timedelta(days=1)
    while True:
        t += timedelta(days=rng.expovariate(rate_per_day))
        # land sessions in waking hours
        t = t.replace(hour=rng.randint(7, 22), minute=rng.randint(0, 59),
                      second=rng.randint(0, 59))
        if t > churn_at or t > DATA_END:
            break
        if rng.random() < 0.35:
            light_session(rng, w, uid, t, platform)
        else:
            shopping_session(rng, w, uid, t, platform, engagement)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--users", type=int, default=6000)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", default="data/user_events.csv")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    w = EventWriter()
    for n in range(1, args.users + 1):
        simulate_user(rng, w, n)

    with open(args.out, "w", newline="") as f:
        out = csv.writer(f)
        out.writerow(["event_id", "user_id", "event_name", "event_timestamp", "platform"])
        for row in w.rows:
            out.writerow([row[0], row[1], row[2],
                          row[3].strftime("%Y-%m-%d %H:%M:%S"), row[4]])

    print(f"Wrote {len(w.rows):,} events for {args.users:,} users to {args.out}")


if __name__ == "__main__":
    main()
