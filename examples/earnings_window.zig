//! Earnings pre-release forecast activity windows via datelist bitmaps.
//! Ports chip-earnings-pilot/calendar.zig pattern for cross-repo reuse.

const std = @import("std");
const datelist = @import("datelist");

const Datelist32 = datelist.Datelist32;

pub fn recordUpdate(activity: *Datelist32, days_before_release: u8) !void {
    const bit = try Datelist32.fromOffsets(&.{days_before_release});
    activity.* = activity.unionWith(bit);
}

pub fn updateDensity(activity: Datelist32, n: u8) u8 {
    if (n == 0) return 0;
    if (n >= Datelist32.window_days) return activity.activeDayCount();
    const mask = (@as(Datelist32.Int, 1) << @intCast(n)) - 1;
    return @intCast(@popCount(activity.bits & mask));
}

test "earnings window walk-forward density" {
    var act = Datelist32.empty;
    // Simulate daily revisions at 90, 60, 30, 7, 1 days before release.
    for ([_]u8{ 90, 60, 30, 7, 1 }) |d| {
        if (d < Datelist32.window_days) try recordUpdate(&act, d);
    }
    try std.testing.expectEqual(@as(u8, 3), act.activeDayCount());
    try std.testing.expect(updateDensity(act, 32) == 3);
}