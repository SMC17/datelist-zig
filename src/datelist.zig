//! datelist — compact bitmap representation of per-day activity over a fixed
//! window ending at a reference date.
//!
//! Ports Zach Wilson's `datelist_int` pattern (DataExpert.io
//! intermediate-bootcamp fact-data-modeling) to Zig with comptime-resolved
//! width and SIMD-friendly cohort algebra.
//!
//! Representation: a `width`-bit unsigned integer where bit `n` is set iff
//! the entity was active `n` days ago relative to the reference date.
//! Bit 0 is the reference day itself; bit `width-1` is the oldest day in the
//! window.

const std = @import("std");

/// Errors returned by datelist constructors.
pub const Error = error{
    /// An offset passed to `fromOffsets` exceeded the bitmap width.
    OffsetOutOfRange,
};

/// Construct a `Datelist` type over an unsigned integer of `width` bits.
/// `width` must be 8, 16, 32, 64, or 128.
pub fn Datelist(comptime width: comptime_int) type {
    comptime {
        switch (width) {
            8, 16, 32, 64, 128 => {},
            else => @compileError("Datelist width must be 8, 16, 32, 64, or 128"),
        }
    }

    return struct {
        const Self = @This();

        /// Underlying unsigned integer holding the bitmap. Public because
        /// callers can serialize it directly to SQL `INT`/`BIGINT` columns.
        pub const Int = std.meta.Int(.unsigned, width);

        /// Width of the window in days (one bit per day).
        pub const window_days: comptime_int = width;

        bits: Int,

        /// Empty bitmap: no day in the window has activity.
        pub const empty: Self = .{ .bits = 0 };

        /// All days in the window active.
        pub const full: Self = .{ .bits = std.math.maxInt(Int) };

        /// Build from a literal underlying bitfield. Bit `n` set ↔ active `n`
        /// days ago.
        pub fn fromBits(bits: Int) Self {
            return .{ .bits = bits };
        }

        /// Build from a slice of day-offsets relative to the reference date.
        /// Returns `OffsetOutOfRange` if any offset is ≥ window width.
        pub fn fromOffsets(offsets: []const u8) Error!Self {
            var bits: Int = 0;
            for (offsets) |off| {
                if (off >= window_days) return Error.OffsetOutOfRange;
                bits |= @as(Int, 1) << @intCast(off);
            }
            return .{ .bits = bits };
        }

        /// Was the entity active exactly `offset` days ago?
        /// Out-of-range offsets return `false`.
        pub fn activeAt(self: Self, offset: u8) bool {
            if (offset >= window_days) return false;
            return (self.bits & (@as(Int, 1) << @intCast(offset))) != 0;
        }

        /// Was the entity active on ANY day within the last `n` days
        /// (offsets 0 through n-1)?
        /// `n == 0` returns false. `n >= window_days` is clamped to the
        /// whole window.
        pub fn anyActiveWithin(self: Self, n: u8) bool {
            if (n == 0) return false;
            const clamped: u8 = if (n >= window_days) window_days else n;
            const mask: Int = lowMask(clamped);
            return (self.bits & mask) != 0;
        }

        /// Count of active days in the window. Single CPU instruction
        /// (`popcnt`) on x86_64; intrinsic on aarch64.
        pub fn activeDayCount(self: Self) u8 {
            return @popCount(self.bits);
        }

        /// Offset of the most-recent active day, or `null` if the entity
        /// has no activity in the window. Single CPU instruction (`tzcnt`)
        /// on x86_64.
        pub fn mostRecentActiveOffset(self: Self) ?u8 {
            if (self.bits == 0) return null;
            return @intCast(@ctz(self.bits));
        }

        /// Offset of the oldest active day in the window, or `null` if no
        /// activity. The bit at this offset is the highest set bit.
        pub fn oldestActiveOffset(self: Self) ?u8 {
            if (self.bits == 0) return null;
            return @intCast(width - 1 - @clz(self.bits));
        }

        /// Cohort algebra: entities active in both windows.
        pub fn intersect(self: Self, other: Self) Self {
            return .{ .bits = self.bits & other.bits };
        }

        /// Cohort algebra: entities active in either window.
        pub fn unionWith(self: Self, other: Self) Self {
            return .{ .bits = self.bits | other.bits };
        }

        /// Cohort algebra: active in `self` but NOT in `other`.
        pub fn minus(self: Self, other: Self) Self {
            return .{ .bits = self.bits & ~other.bits };
        }

        /// Cohort algebra: symmetric difference.
        pub fn symDiff(self: Self, other: Self) Self {
            return .{ .bits = self.bits ^ other.bits };
        }

        /// Shift the bitmap forward by `days_advanced` days (the reference
        /// date moves forward in time). Bits shift toward higher offsets;
        /// activity that ages out of the window is dropped. Bit 0 of the
        /// result represents the new reference day; the caller is
        /// responsible for OR-ing in any new activity that occurred on
        /// the days advanced past.
        pub fn shiftForward(self: Self, days_advanced: u8) Self {
            if (days_advanced >= window_days) return empty;
            return .{ .bits = self.bits << @intCast(days_advanced) };
        }

        /// True iff bitmap has no active day in the window.
        pub fn isEmpty(self: Self) bool {
            return self.bits == 0;
        }

        /// Equality.
        pub fn eql(self: Self, other: Self) bool {
            return self.bits == other.bits;
        }

        /// Write the active day-offsets, ascending, into `buf`. Returns
        /// the number of offsets written. `buf` must be at least
        /// `window_days` long for the worst case.
        pub fn toOffsets(self: Self, buf: []u8) usize {
            var n: usize = 0;
            var off: u8 = 0;
            while (off < window_days) : (off += 1) {
                if (self.activeAt(off)) {
                    buf[n] = off;
                    n += 1;
                }
            }
            return n;
        }

        /// Mask of the low `n` bits as the underlying integer type.
        /// `n` must be ≤ `window_days`.
        fn lowMask(n: u8) Int {
            if (n >= window_days) return std.math.maxInt(Int);
            return (@as(Int, 1) << @intCast(n)) - 1;
        }
    };
}

// Canonical instantiations matching the common SQL representations:
//   - 32 days fits in a SQL INT (4 bytes), the original Zach pattern.
//   - 64 days fits in a SQL BIGINT (8 bytes), two months of presence.
//   - 128 days fits in a SQL DECIMAL(38) or two BIGINTs, ~4 months.

pub const Datelist32 = Datelist(32);
pub const Datelist64 = Datelist(64);
pub const Datelist128 = Datelist(128);

// --- Tests ----------------------------------------------------------------

test "fromBits round-trip" {
    const d = Datelist32.fromBits(0b1010_0101);
    try std.testing.expectEqual(@as(u32, 0b1010_0101), d.bits);
}

test "fromOffsets builds expected bitmap" {
    const d = try Datelist32.fromOffsets(&.{ 0, 2, 5, 7 });
    try std.testing.expectEqual(@as(u32, 0b1010_0101), d.bits);
}

test "fromOffsets rejects out-of-range" {
    try std.testing.expectError(Error.OffsetOutOfRange, Datelist32.fromOffsets(&.{32}));
    try std.testing.expectError(Error.OffsetOutOfRange, Datelist64.fromOffsets(&.{64}));
}

test "activeAt at boundaries" {
    const d = try Datelist32.fromOffsets(&.{ 0, 31 });
    try std.testing.expect(d.activeAt(0));
    try std.testing.expect(d.activeAt(31));
    try std.testing.expect(!d.activeAt(1));
    try std.testing.expect(!d.activeAt(30));
    // out-of-range is always false
    try std.testing.expect(!d.activeAt(32));
    try std.testing.expect(!d.activeAt(255));
}

test "anyActiveWithin semantics" {
    const d = try Datelist32.fromOffsets(&.{5});
    try std.testing.expect(!d.anyActiveWithin(0));
    try std.testing.expect(!d.anyActiveWithin(5)); // covers offsets 0..4
    try std.testing.expect(d.anyActiveWithin(6)); // covers offsets 0..5
    try std.testing.expect(d.anyActiveWithin(32));
    try std.testing.expect(d.anyActiveWithin(255)); // clamped
}

test "anyActiveWithin on empty is false" {
    const d = Datelist32.empty;
    try std.testing.expect(!d.anyActiveWithin(32));
}

test "activeDayCount via popcount" {
    try std.testing.expectEqual(@as(u8, 0), Datelist32.empty.activeDayCount());
    try std.testing.expectEqual(@as(u8, 32), Datelist32.full.activeDayCount());
    const d = try Datelist32.fromOffsets(&.{ 0, 2, 5, 7, 15, 31 });
    try std.testing.expectEqual(@as(u8, 6), d.activeDayCount());
}

test "mostRecentActiveOffset" {
    try std.testing.expect(Datelist32.empty.mostRecentActiveOffset() == null);
    const d = try Datelist32.fromOffsets(&.{ 3, 7, 15 });
    try std.testing.expectEqual(@as(?u8, 3), d.mostRecentActiveOffset());
}

test "oldestActiveOffset" {
    try std.testing.expect(Datelist32.empty.oldestActiveOffset() == null);
    const d = try Datelist32.fromOffsets(&.{ 3, 7, 15 });
    try std.testing.expectEqual(@as(?u8, 15), d.oldestActiveOffset());
    const d2 = try Datelist32.fromOffsets(&.{31});
    try std.testing.expectEqual(@as(?u8, 31), d2.oldestActiveOffset());
}

test "intersect / union / minus / symDiff cohort algebra" {
    const a = Datelist32.fromBits(0b1100_1010);
    const b = Datelist32.fromBits(0b1010_1100);

    try std.testing.expectEqual(@as(u32, 0b1000_1000), a.intersect(b).bits);
    try std.testing.expectEqual(@as(u32, 0b1110_1110), a.unionWith(b).bits);
    try std.testing.expectEqual(@as(u32, 0b0100_0010), a.minus(b).bits);
    try std.testing.expectEqual(@as(u32, 0b0110_0110), a.symDiff(b).bits);
}

test "shiftForward ages the window" {
    const d = try Datelist32.fromOffsets(&.{ 0, 5 });
    // Advance one day. The day that was bit 0 is now bit 1.
    const after = d.shiftForward(1);
    try std.testing.expect(!after.activeAt(0)); // new reference day, no activity yet
    try std.testing.expect(after.activeAt(1));
    try std.testing.expect(after.activeAt(6));
    // Advance off the end → empty.
    try std.testing.expectEqual(@as(u32, 0), d.shiftForward(32).bits);
    try std.testing.expectEqual(@as(u32, 0), d.shiftForward(200).bits);
}

test "toOffsets round-trips with fromOffsets" {
    const offsets = [_]u8{ 0, 1, 3, 9, 17, 31 };
    const d = try Datelist32.fromOffsets(&offsets);
    var buf: [32]u8 = undefined;
    const n = d.toOffsets(&buf);
    try std.testing.expectEqual(offsets.len, n);
    try std.testing.expectEqualSlices(u8, &offsets, buf[0..n]);
}

test "Datelist64 + Datelist128 instantiate cleanly" {
    const d64 = try Datelist64.fromOffsets(&.{ 0, 63 });
    try std.testing.expectEqual(@as(u64, (1 << 63) | 1), d64.bits);
    const d128 = try Datelist128.fromOffsets(&.{ 0, 127 });
    try std.testing.expectEqual(@popCount(d128.bits), 2);
}

test "popcount matches @popCount over every 16-bit pattern" {
    var i: u16 = 0;
    while (true) : (i += 1) {
        const d = Datelist(16).fromBits(i);
        try std.testing.expectEqual(@as(u8, @popCount(i)), d.activeDayCount());
        if (i == std.math.maxInt(u16)) break;
    }
}

test "Datelist32 size is 4 bytes" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Datelist32));
}

test "fromBits / activeAt / popcount are pure value-semantics" {
    const a = Datelist32.fromBits(0b1010);
    const b = Datelist32.fromBits(0b0101);
    _ = a.intersect(b);
    // a and b unchanged
    try std.testing.expectEqual(@as(u32, 0b1010), a.bits);
    try std.testing.expectEqual(@as(u32, 0b0101), b.bits);
}
