# 8 × 30-min batch benchmark history — gate evidence for ead64e2 / 0efa96a / 9ae7084

All runs: 8 × 30-minute stereo pink-noise WAVs, "Both" mode at defaults
(−18 LUFS / −1.0 dBTP / 160 kbps / 44.1 kHz), M3 Pro (12 cores). "Perceived"
= file-written completions + trailing verification + post-render Swift tails.
The final passing run's raw report is capgate-final.txt; earlier rows are
recorded from the session's gate logs and the corresponding commit messages.

| run | architecture | last completion | perceived | vs 626.1 s baseline | verdict |
|---|---|---|---|---|---|
| audit, cap 6 | inline verification, scalar Swift passes | — | 626.1 s | 1.00× (baseline) | reference |
| audit, cap 11 | inline verification (experiment) | — | 370.4 s | 1.69× | reference |
| cap 11, attempt 1 | sequential post-delivery verify phase | 296.4 s | 435.6 s | 1.44× | **gate FAILED** (bar 1.5×) |
| cap 6 + pool 3 | verification pool (ead64e2 gate) | 499.0 s | 544.9 s | (preview) | resource gate pass |
| cap 11, attempt 2 | pool of 3 | 280.4 s | 432.4 s | 1.448× | **gate FAILED** — arrivals synchronize at cap ≥ queue; ~384 CPU-s of verifies through 3 slots = ~152 s tail at 70% machine idle |
| cap 6 + pool 6 | widened pool (0efa96a gate) | 494.4 s | 532.8 s | (preview) | resource gate pass; tail 38.4 s |
| **cap 11 + pool 6** | final (9ae7084 gate) | **277.8 s (2.25×)** | **381.7 s** | **1.64×** | **PASS** (bar 1.5×; projection 350–365 s, +5–9% delta attributed to MP3 loudnorm verifies slowing under 6-wide contention with Swift tails) |

Resource acceptance at the final run: peak 10 concurrent ffmpeg (3 s
sampling), peak ffmpeg RSS 497 MB, machine CPU 98% peak / 76% avg, MainActor
heartbeat drift mean 1.1 ms / max 11.5 ms over 3776 ticks.

Lesson recorded for future cap changes: when the delivery cap meets or
exceeds the queue depth, every file completes in a single wave, so ALL
verification arrivals synchronize and pool width becomes the only tail
parallelism. Re-check verificationConcurrency whenever deliveryConcurrency
changes.
