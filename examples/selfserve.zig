//! Synthetic rolling-activity task: fixed input, visible window semantics.
const std = @import("std");
const lib = @import("lib");
pub fn main() !void {
    const activity = try lib.Datelist32.fromOffsets(&.{ 0, 1, 7 });
    const tomorrow = activity.shiftForward(1);
    if (activity.activeDayCount() != 3 or tomorrow.activeAt(0) or !tomorrow.activeAt(8)) return error.WindowMismatch;
    std.debug.print("fixture: active_days=3 window_days=32 next_day_oldest_offset=8\n", .{});
}
