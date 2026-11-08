# Executive Memo: Funnel, Checkout Abandonment and Early Retention

**Bottom line:** checkout, not the catalog, is where we lose buyers, and Android checkout is the worst of it. Fixing Android checkout to match web and iOS would raise 14-day conversion from 38.4% to about 41.0%. Separately, new users who use the search filter on day 1 retain far better; this is worth testing with an onboarding prompt.

*Based on 6,000 users and 334,078 events (May to September 2026, synthetic data). Full method and query output: see the README and `results/`.*

## 1. The funnel leaks at checkout

Within 14 days of signup:

| Step | Users | Step conversion |
|---|---:|---:|
| Sign up | 5,620 | |
| View catalog | 5,562 | 99.0% |
| Add to cart | 3,777 | 67.9% |
| Purchase | 2,160 | **57.2%** |

Catalog to cart loses slightly more people in absolute terms, but cart to purchase has the highest failure rate among people who have already shown intent to buy.

## 2. Shipping costs end most abandoned carts

- **56.7%** of abandoned carts end on the shipping-cost screen.
- Only about **26%** of abandoners return and buy within 7 days, so most of these sales are lost, not delayed.

## 3. Android checkout is broken relative to other platforms

| Platform | Cart → purchase | Leave at shipping screen |
|---|---:|---:|
| iOS | 61.1% | 43.9% |
| Web | 60.9% | 42.3% |
| Android | **45.1%** | **62.9%** |

Browsing behaviour is the same across platforms, so this is a checkout problem, not an audience difference.

## 4. Day-1 search filter use is the strongest retention signal

| Day-1 action | Day-30 retention (did it) | (didn't) | Lift after adjusting for day-1 activity |
|---|---:|---:|---:|
| Use search filter | 47.9% | 25.7% | **+19.6 pp** |
| Set up profile | 40.3% | 30.8% | +8.2 pp |
| Invite a friend | 40.8% | 34.1% | +4.6 pp |

These are associations, not proven causes. Engaged users do more of everything. Inviting a friend is a warning example: it was built into the simulated data with **no effect at all**, yet it still shows a positive lift after adjustment.

## Recommendations

1. **Investigate and fix Android checkout first.** It is the largest, most specific gap: roughly 144 extra purchasers in this cohort.
2. **Show shipping costs earlier**, on the product or cart page, so they don't first appear at the last step.
3. **Run an A/B test of a search-filter prompt in onboarding** before investing further; measure Day-30 retention as the primary outcome.
4. **Don't prioritise the invite flow for retention** on this evidence.
