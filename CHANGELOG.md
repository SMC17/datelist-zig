# Changelog

## 2026-11-11 self-serve task

- Add a runnable synthetic task, clean-source packager and gated preview workflow.
- Wire the earnings-window example into the test step and correct its expected count: only three of five supplied offsets fit the 32-day window.
- Accept the standard -Doptimize option; default builds use Debug and packaged demos use ReleaseSafe.

## 0.0.1 — 2026-05-28

Substrate primitives + SIMD cohort scan. 24/24 tests pass on Zig 0.16.

Ports the `datelist_int` bitmap pattern from Zach Wilson's DataExpert.io
fact-data-modeling bootcamp to Zig.

### What ships

- `Datelist(width)` generic over `width ∈ {8, 16, 32, 64, 128}`.
- `Datelist32` / `Datelist64` / `Datelist128` aliases.
- `fromBits` / `fromOffsets` / `toOffsets` constructors.
- `activeAt` / `anyActiveWithin` / `activeDayCount` /
  `mostRecentActiveOffset` / `oldestActiveOffset` predicates.
- `intersect` / `unionWith` / `minus` / `symDiff` cohort algebra.
- `shiftForward` window aging.
- `cohortAnyActiveWithin` / `cohortIntersectCount` /
  `cohortActiveDayTotal` SIMD scans via `@Vector(N, Int)`.

### Open for v0.0.2

- Postgres parity cross-bench. Verify the bit-field encoding matches the
  canonical SQL representation Zach teaches.
- Bench harness (`bench/bench_cohort.zig`) measuring SIMD vs scalar at
  1M-entity cohort intersection.
- ARM verification — cross-compile aarch64 + run-in-emulator gate.
- Bench result: ≥4× over scalar at AVX2 host, single thread, ReleaseFast.
