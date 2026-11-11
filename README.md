# datelist-zig

Try the [self-contained task](docs/SELF_SERVE.md): `zig build demo`.

[![License: AGPL-3.0-or-later](https://img.shields.io/badge/License-AGPL--3.0--or--later-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16-orange.svg)](https://ziglang.org/)

This library ports [Zach Wilson](https://www.linkedin.com/in/eczachly)'s
**`datelist_int`** pattern (taught at [DataExpert.io](https://www.dataexpert.io)
in his fact-data-modeling bootcamp) to Zig with comptime-resolved width
and SIMD-friendly cohort algebra. The original SQL pattern is the on-ramp;
this port pushes it on footprint, comptime-spec, and cohort-scan throughput.

## What it is

A compact representation of per-day activity over a fixed window ending at
a reference date. Each entity is stored as one unsigned integer where bit
`n` is set iff the entity was active `n` days ago. Bit 0 is the reference
day; bit `width-1` is the oldest day.

The 32-day form (`Datelist32`) is the Zach pattern: 32 days of presence in
4 bytes. The library also instantiates 8 / 16 / 64 / 128-bit windows for
shorter rolling windows and longer multi-month windows.

## Status

**v0.0.1 — 24/24 tests pass on Zig 0.16.** Substrate primitives + SIMD
cohort scan for any-active-within / intersect-count / total-day-count.
Postgres parity cross-bench and bench harness are v0.0.2 work.

## What ships

- `Datelist(width)` — generic over `width ∈ {8, 16, 32, 64, 128}`. Stored
  as a single unsigned integer; `@sizeOf(Datelist32) == 4`.
- `Datelist32` / `Datelist64` / `Datelist128` — canonical aliases.
- `fromBits` / `fromOffsets` / `toOffsets` constructors and round-trip.
- `activeAt(offset)` / `anyActiveWithin(n)` / `activeDayCount()` /
  `mostRecentActiveOffset()` / `oldestActiveOffset()` predicates.
- `intersect` / `unionWith` / `minus` / `symDiff` cohort algebra. Pure
  value semantics, no allocator.
- `shiftForward(days_advanced)` ages the window forward by N days. Bits
  shift toward higher offsets; activity that drops off the end is gone.
- `cohortAnyActiveWithin(slice, n)` / `cohortIntersectCount(a, b)` /
  `cohortActiveDayTotal(slice)` — SIMD cohort scans via `@Vector(N, Int)`.
  Lane count tuned for AVX2 (256-bit) / NEON (128-bit) at the underlying
  integer width.

## What ships does NOT do (yet)

- No Postgres / ClickHouse parity cross-bench. v0.0.2 gate is that
  `Datelist32.fromOffsets(...)` produces the same bits as the canonical
  Zach SQL emits for the same input.
- No serialization helper. The underlying `bits: Int` field is public
  precisely so callers can write it straight to a SQL `INT` / `BIGINT`
  / `DECIMAL(38)` column without ceremony.
- No multi-period windows (`[N]u64`). v0.0.3.
- No streaming-update path for high-frequency event ingest. v0.0.3.

## Quickstart

```zig
const std = @import("std");
const dl = @import("datelist");

pub fn main() !void {
    // Active today, two days ago, five days ago, twelve days ago.
    const a = try dl.Datelist32.fromOffsets(&.{ 0, 2, 5, 12 });

    std.debug.print("active days: {d}\n", .{a.activeDayCount()});
    std.debug.print("most recent: {?}\n", .{a.mostRecentActiveOffset()});
    std.debug.print("active in last 7 days: {}\n", .{a.anyActiveWithin(7)});

    // Cohort intersection across many entities.
    var cohort: [10_000]dl.Datelist32 = undefined;
    // ... fill cohort from your data layer ...

    const active_7d = dl.cohortAnyActiveWithin(32, &cohort, 7);
    std.debug.print("{d} of {d} active in last 7 days\n", .{ active_7d, cohort.len });
}
```

## Build

```sh
zig build test                  # 24 unit tests + SIMD cohort tests
```

Requires Zig 0.16. No system dependencies, no C interop.

## The pattern in SQL

For reference, this is the operation `datelist-zig` ports — taught in
Zach's bootcamp (`materials/2-fact-data-modeling/lecture-lab/`):

```sql
WITH starter AS (
  SELECT user_id,
         CASE WHEN active THEN POW(2, 32 - days_since) ELSE 0 END AS placement
  FROM cumulated CROSS JOIN date_range
),
bits AS (
  SELECT user_id, SUM(placement)::bit(32) AS datelist_int
  FROM starter
  GROUP BY user_id
)
SELECT user_id,
       BIT_COUNT(datelist_int) > 0 AS monthly_active,
       BIT_COUNT(datelist_int & CAST('1111111000000000000000000000000' AS BIT(32))) > 0
         AS weekly_active
FROM bits;
```

`BIT_COUNT(datelist_int)` is `Datelist32.activeDayCount()`. The
`monthly_active` predicate is `!d.isEmpty()`. The `weekly_active`
predicate is `d.anyActiveWithin(7)`. Cohort algebra (`AND` / `OR` /
`XOR`) ports straight across.

## Honest non-claims

- Pre-1.0 substrate per Zig 0.16 ecosystem convention. Vocabulary stays
  below release-readiness language until the evidence changes.
- Numbers about SIMD speedup are not yet published. v0.0.2 bench gate is
  ≥4× over the equivalent scalar loop at 1M-entity cohort intersection,
  AVX2 host, single thread, ReleaseFast.
- Cross-platform bit-identical output is asserted by the spec but only
  measured on x86_64-linux at v0.0.1. ARM verification is a v0.0.2 gate.
- The Postgres SQL above is the parity target; the cross-bench that
  proves byte-equality of the bitfield representation is v0.0.2 work.

## Credit

Concept adapted from [Zach Wilson](https://www.linkedin.com/in/eczachly) (DataExpert.io).
Frontier port by Sean Collins (`sean@sunlitmoon.online`).

## License

AGPL-3.0-or-later. See `LICENSE`.
