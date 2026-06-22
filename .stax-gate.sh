# stax-gate config for datelist-zig — generated 2026-06-15. Edit the bench line.
GATE_BUILD="zig build"
GATE_TEST="zig build test"
GATE_BENCH="zig build bench 2>/dev/null"   # VERIFY: emits one metric number
GATE_THRESHOLD_PCT=3
GATE_BENCH_RUNS=5
GATE_LOWER_IS_BETTER=1
GATE_LANE="gate:datelist-zig"
