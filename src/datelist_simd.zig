//! SIMD cohort primitives over `Datelist(width)` arrays.
//!
//! These operate on a slice of bitmaps (one per entity) and return a single
//! aggregate count without allocating. The inner loop maps to
//! `@Vector(N, Int)` over the underlying bitfield integer, which LLVM
//! lowers to AVX2 / NEON intrinsics at ReleaseFast.

const std = @import("std");
const datelist = @import("datelist.zig");

/// Lane width tuned for x86_64 AVX2 (256-bit register) and aarch64 NEON
/// (128-bit register). On AVX2: 8×u32, 4×u64, 2×u128. On NEON the wider
/// lane widths split into two stores per op — LLVM handles this.
fn laneCount(comptime Int: type) comptime_int {
    return switch (@bitSizeOf(Int)) {
        8 => 32,
        16 => 16,
        32 => 8,
        64 => 4,
        128 => 2,
        else => @compileError("unsupported integer width for SIMD cohort scan"),
    };
}

/// Count entities active on ANY day within the last `n` days.
/// `n == 0` always returns 0. `n >= window_days` returns the count of
/// entities with any activity in the window.
pub fn cohortAnyActiveWithin(
    comptime width: comptime_int,
    cohort: []const datelist.Datelist(width),
    n: u8,
) usize {
    if (n == 0 or cohort.len == 0) return 0;
    const DL = datelist.Datelist(width);
    const Int = DL.Int;
    const mask: Int = if (n >= DL.window_days)
        std.math.maxInt(Int)
    else
        (@as(Int, 1) << @intCast(n)) - 1;

    const N = comptime laneCount(Int);
    const V = @Vector(N, Int);
    const zero: V = @splat(0);
    const mask_v: V = @splat(mask);
    var count: usize = 0;

    var i: usize = 0;
    while (i + N <= cohort.len) : (i += N) {
        var vec: V = undefined;
        comptime var lane: usize = 0;
        inline while (lane < N) : (lane += 1) {
            vec[lane] = cohort[i + lane].bits;
        }
        const ored = vec & mask_v;
        const nz = ored != zero;
        // @reduce(.Add, @select bool→int) is the SIMD popcount of `nz`.
        comptime var l: usize = 0;
        inline while (l < N) : (l += 1) {
            if (nz[l]) count += 1;
        }
    }
    while (i < cohort.len) : (i += 1) {
        if ((cohort[i].bits & mask) != 0) count += 1;
    }
    return count;
}

/// Count entities active in BOTH `a` and `b` on at least one day.
/// Cohorts must be the same length (one bitmap per entity, aligned).
pub fn cohortIntersectCount(
    comptime width: comptime_int,
    a: []const datelist.Datelist(width),
    b: []const datelist.Datelist(width),
) usize {
    std.debug.assert(a.len == b.len);
    if (a.len == 0) return 0;
    const DL = datelist.Datelist(width);
    const Int = DL.Int;
    const N = comptime laneCount(Int);
    const V = @Vector(N, Int);
    const zero: V = @splat(0);
    var count: usize = 0;

    var i: usize = 0;
    while (i + N <= a.len) : (i += N) {
        var va: V = undefined;
        var vb: V = undefined;
        comptime var lane: usize = 0;
        inline while (lane < N) : (lane += 1) {
            va[lane] = a[i + lane].bits;
            vb[lane] = b[i + lane].bits;
        }
        const inter = va & vb;
        const nz = inter != zero;
        comptime var l: usize = 0;
        inline while (l < N) : (l += 1) {
            if (nz[l]) count += 1;
        }
    }
    while (i < a.len) : (i += 1) {
        if ((a[i].bits & b[i].bits) != 0) count += 1;
    }
    return count;
}

/// Sum of active-day counts across the cohort — the total person-days of
/// activity. Uses vector `@popCount` lane-wise then `@reduce(.Add, …)`.
pub fn cohortActiveDayTotal(
    comptime width: comptime_int,
    cohort: []const datelist.Datelist(width),
) u64 {
    if (cohort.len == 0) return 0;
    const DL = datelist.Datelist(width);
    const Int = DL.Int;
    const N = comptime laneCount(Int);
    const V = @Vector(N, Int);
    var total: u64 = 0;

    var i: usize = 0;
    while (i + N <= cohort.len) : (i += N) {
        var vec: V = undefined;
        comptime var lane: usize = 0;
        inline while (lane < N) : (lane += 1) {
            vec[lane] = cohort[i + lane].bits;
        }
        // Widen popcount per lane to u64 before summing — the popcount
        // result has the input's element type (e.g. u8 at width=8), and
        // summing 32 lanes of u8 popcounts overflows on dense bitmaps.
        const pc = @popCount(vec);
        const pc_wide: @Vector(N, u64) = pc;
        total += @reduce(.Add, pc_wide);
    }
    while (i < cohort.len) : (i += 1) {
        total += @popCount(cohort[i].bits);
    }
    return total;
}

// --- Tests ----------------------------------------------------------------

const Datelist32 = datelist.Datelist32;

test "cohortAnyActiveWithin matches scalar" {
    var entities: [100]Datelist32 = undefined;
    for (&entities, 0..) |*e, i| {
        e.* = Datelist32.fromBits(@truncate(@as(u64, i) *% 0x9E3779B97F4A7C15));
    }
    const window: u8 = 7;
    var scalar_count: usize = 0;
    for (entities) |e| if (e.anyActiveWithin(window)) {
        scalar_count += 1;
    };
    const simd_count = cohortAnyActiveWithin(32, &entities, window);
    try std.testing.expectEqual(scalar_count, simd_count);
}

test "cohortAnyActiveWithin handles non-lane-multiple sizes" {
    var entities: [13]Datelist32 = undefined;
    for (&entities, 0..) |*e, i| e.* = Datelist32.fromOffsets(&.{@intCast(i % 32)}) catch unreachable;
    // Each entity is active on day i (mod 32). Within last 5 days: i=0..4.
    try std.testing.expectEqual(@as(usize, 5), cohortAnyActiveWithin(32, &entities, 5));
}

test "cohortAnyActiveWithin n=0 always 0" {
    var entities: [10]Datelist32 = .{Datelist32.full} ** 10;
    try std.testing.expectEqual(@as(usize, 0), cohortAnyActiveWithin(32, &entities, 0));
}

test "cohortAnyActiveWithin empty cohort is 0" {
    const entities: []const Datelist32 = &.{};
    try std.testing.expectEqual(@as(usize, 0), cohortAnyActiveWithin(32, entities, 7));
}

test "cohortIntersectCount matches scalar" {
    var a: [200]Datelist32 = undefined;
    var b: [200]Datelist32 = undefined;
    for (&a, &b, 0..) |*ax, *bx, i| {
        ax.* = Datelist32.fromBits(@truncate(@as(u64, i) *% 0xBF58476D1CE4E5B9));
        bx.* = Datelist32.fromBits(@truncate(@as(u64, i) *% 0x94D049BB133111EB));
    }
    var scalar: usize = 0;
    for (a, b) |ax, bx| if (!ax.intersect(bx).isEmpty()) {
        scalar += 1;
    };
    const simd = cohortIntersectCount(32, &a, &b);
    try std.testing.expectEqual(scalar, simd);
}

test "cohortActiveDayTotal matches scalar over varied widths" {
    inline for (.{ 8, 16, 32, 64, 128 }) |w| {
        const DL = datelist.Datelist(w);
        var entities: [50]DL = undefined;
        for (&entities, 0..) |*e, i| e.* = DL.fromBits(@as(DL.Int, @truncate(@as(u128, i) *% 0x9E3779B97F4A7C15)));
        var scalar: u64 = 0;
        for (entities) |e| scalar += e.activeDayCount();
        try std.testing.expectEqual(scalar, cohortActiveDayTotal(w, &entities));
    }
}

test "cohortIntersectCount on disjoint cohorts is 0" {
    const a: [4]Datelist32 = .{
        Datelist32.fromBits(0b0001),
        Datelist32.fromBits(0b0010),
        Datelist32.fromBits(0b0100),
        Datelist32.fromBits(0b1000),
    };
    const b: [4]Datelist32 = .{
        Datelist32.fromBits(0b1110),
        Datelist32.fromBits(0b1101),
        Datelist32.fromBits(0b1011),
        Datelist32.fromBits(0b0111),
    };
    try std.testing.expectEqual(@as(usize, 0), cohortIntersectCount(32, &a, &b));
}
