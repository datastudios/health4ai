---
title: "Blood Oxygen and Respiratory Rate: AI Analysis with Apple Health Data"
description: "How to query SpO2 and respiratory rate from HealthKit, what the data looks like, and what questions are worth asking Claude about these metrics."
pubDate: 2026-09-19
slug: "blood-oxygen-respiratory-rate-ai"
tags: ["blood-oxygen", "spo2", "respiratory-rate", "apple-health", "healthkit", "mcp", "analysis"]
draft: false
---

# Blood Oxygen and Respiratory Rate: AI Analysis with Apple Health Data

Blood oxygen (SpO2) and respiratory rate are two metrics Apple Watch captures that get less attention than HRV and sleep, but they're meaningfully informative — particularly for spotting illness onset, altitude effects, and sleep quality indicators. Here's how to query and interpret them.

## Blood Oxygen (SpO2)

Apple Watch Series 6 and later measures blood oxygen saturation. The HealthKit identifier is `HKQuantityTypeIdentifierOxygenSaturation`. Values are expressed as a fraction (0.98 = 98% SpO2).

**Measurement context:** Apple Watch measures SpO2 in the background during sleep and when you manually take a reading via the Blood Oxygen app. During sleep, it measures every few minutes. The background measurements are automatic when Sleep Mode is active.

**What's normal:** Healthy resting SpO2 is typically 95-100%. Below 90% is clinically significant. For Apple Watch's consumer-grade sensor, expect ±1-2% accuracy — it's useful for trend monitoring and flagging unusually low readings, not for clinical decisions.

**Querying SpO2:**

```
Show me my blood oxygen levels over the last 30 days.
```

Claude calls `query_metric(metric_type="HKQuantityTypeIdentifierOxygenSaturation", days=30)`.

For a 30-day window, this returns daily aggregates — the day's average SpO2, min, and max. The min value is often the most informative, as it captures the lowest reading during the night.

**Checking for nocturnal dips:**

```
Were there any nights in the last 90 days where my blood oxygen dropped below 94%?
```

Claude uses `search_records(metric_type="HKQuantityTypeIdentifierOxygenSaturation", max_value=0.94, days=90)`.

Note: SpO2 in HealthKit is stored as a decimal fraction, not a percentage — 0.94 = 94%, 0.98 = 98%.

**Altitude effects:**

If you travel to high altitude (ski trips, mountain hiking), SpO2 often drops as the body acclimates. 

```
I went skiing in Colorado in early March at around 9,000 feet. Can you see any SpO2 changes during that trip?
```

Claude pulls `query_metric(metric_type="HKQuantityTypeIdentifierOxygenSaturation", days=30)` (or uses `compare_periods` with the travel dates) and looks for SpO2 dips in the relevant window.

**Illness correlation:**

SpO2 can drop slightly during respiratory illness (cold, flu, COVID). 

```
Did my blood oxygen show any patterns during January when I was sick?
```

Claude uses `compare_periods` with pre-illness, during-illness, and recovery dates.

## Respiratory Rate

Respiratory rate is measured by Apple Watch Series 3 and later during sleep. The HealthKit identifier is `HKQuantityTypeIdentifierRespiratoryRate`. Unit: breaths per minute.

**When it's measured:** Apple Watch measures respiratory rate during sleep — typically every few minutes while you're lying still. You won't see readings during your active day; this is a sleep-time metric.

**What's normal:** Resting respiratory rate for adults is typically 12-20 breaths/minute. During sleep, it's often in the lower end of that range. Elevated respiratory rate during sleep can indicate illness, stress, or sleep-disordered breathing.

**Querying respiratory rate:**

```
What's my respiratory rate trend over the last 60 days?
```

Claude calls `query_metric(metric_type="HKQuantityTypeIdentifierRespiratoryRate", days=60)`.

For a 60-day window, this returns daily averages. You'll see your baseline (typically 14-17 breaths/min for most healthy adults) and any deviations.

**Illness detection:**

Elevated respiratory rate during sleep is one of the earliest indicators of respiratory illness — often appearing before you feel sick. 

```
Show me days in the last 90 days where my nighttime respiratory rate was above 17 breaths per minute.
```

Claude uses `search_records(metric_type="HKQuantityTypeIdentifierRespiratoryRate", min_value=17, days=90)`.

**Correlation with sleep and HRV:**

```
On nights where my respiratory rate was elevated (above 16), how was my HRV the next morning?
```

Claude identifies high-respiratory-rate nights from `query_metric`, then checks the HRV for the following morning from `get_hrv_trend`. Elevated respiratory rate and suppressed HRV often co-occur during illness or high stress — seeing both simultaneously strengthens the signal.

## Combining SpO2, Respiratory Rate, and HRV

The three metrics together form a respiratory health picture:

- Normal SpO2 + normal respiratory rate + normal HRV = everything is fine
- Low SpO2 + elevated respiratory rate + suppressed HRV = potential respiratory illness or sleep disruption
- Normal SpO2 + elevated respiratory rate + suppressed HRV = could be stress, anxiety, or early illness
- Low SpO2 + normal respiratory rate = possible altitude, or the reading was an artifact

```
Look at my SpO2, respiratory rate, and HRV over the last 7 days. 
Is there any pattern that would suggest I might be getting sick?
```

Claude pulls all three metrics and looks for the co-occurrence pattern. If SpO2 has been creeping down (98% → 97% → 96%) and respiratory rate has been elevated for 2 consecutive nights, that's a flag worth noting — even if you feel fine.

This kind of early-warning analysis from biometric trends is genuinely useful, even with the caveats about Apple Watch measurement accuracy. The trend direction is more informative than any single absolute reading.

---

health4ai: Free while in early access.  
[Download on the App Store →](https://health4.ai)
