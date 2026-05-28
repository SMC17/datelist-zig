//! Public surface of the `datelist` module.

const datelist = @import("datelist.zig");
const simd = @import("datelist_simd.zig");

pub const Datelist = datelist.Datelist;
pub const Datelist32 = datelist.Datelist32;
pub const Datelist64 = datelist.Datelist64;
pub const Datelist128 = datelist.Datelist128;
pub const Error = datelist.Error;

pub const cohortAnyActiveWithin = simd.cohortAnyActiveWithin;
pub const cohortIntersectCount = simd.cohortIntersectCount;
pub const cohortActiveDayTotal = simd.cohortActiveDayTotal;

test {
    @import("std").testing.refAllDecls(@This());
}
