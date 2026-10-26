//! Float32 math with Bedrock rounding behaviour.
//!
//! Every operation rounds to f32 after each step, matching the client's
//! strict IEEE evaluation. Do not reorder expressions in this module or its
//! callers: algebraically equal forms round differently.

const std = @import("std");

pub const Vec3 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub const zero: Vec3 = .{};

    pub inline fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub inline fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub inline fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub inline fn scale(a: Vec3, s: f32) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }

    pub inline fn mul(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x * b.x, .y = a.y * b.y, .z = a.z * b.z };
    }

    pub inline fn lenSqr(a: Vec3) f32 {
        return a.x * a.x + a.y * a.y + a.z * a.z;
    }

    pub inline fn len(a: Vec3) f32 {
        return @sqrt(a.lenSqr());
    }

    pub inline fn get(a: Vec3, axis: Axis) f32 {
        return switch (axis) {
            .x => a.x,
            .y => a.y,
            .z => a.z,
        };
    }

    pub inline fn set(a: *Vec3, axis: Axis, v: f32) void {
        switch (axis) {
            .x => a.x = v,
            .y => a.y = v,
            .z => a.z = v,
        }
    }

    pub inline fn eql(a: Vec3, b: Vec3) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z;
    }

    pub inline fn isFinite(a: Vec3) bool {
        return std.math.isFinite(a.x) and std.math.isFinite(a.y) and std.math.isFinite(a.z);
    }

    pub fn format(v: Vec3, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("({d}, {d}, {d})", .{ v.x, v.y, v.z });
    }
};

/// Horizontal input: `x` strafes, `y` moves forward.
pub const Vec2 = extern struct {
    x: f32 = 0,
    y: f32 = 0,

    pub inline fn isFinite(a: Vec2) bool {
        return std.math.isFinite(a.x) and std.math.isFinite(a.y);
    }
};

pub const Axis = enum(u2) { x, y, z };

pub inline fn hzLenSqr(v: Vec3) f32 {
    return v.x * v.x + v.z * v.z;
}

pub inline fn clamp(v: f32, lo: f32, hi: f32) f32 {
    if (v < lo) return lo;
    return @min(v, hi);
}

/// Floors to a block coordinate. The caller must ensure `blockCoordInRange`.
/// Truncation avoids a libm call on CPUs without SSE4.1.
pub inline fn floorI(v: f32) i32 {
    const t: i32 = @intFromFloat(v);
    return t - @intFromBool(@as(f32, @floatFromInt(t)) > v);
}

/// Ceils to a block coordinate. The caller must ensure `blockCoordInRange`.
pub inline fn ceilI(v: f32) i32 {
    const t: i32 = @intFromFloat(v);
    return t + @intFromBool(@as(f32, @floatFromInt(t)) < v);
}

/// Returns true when `@floor(v)` fits in an i32.
/// Bounds world-space coordinates to |v| < 2^30, which leaves headroom for
/// neighbour offsets in i32. Real worlds are far smaller.
pub inline fn blockCoordInRange(v: f32) bool {
    return v > -1073741824.0 and v < 1073741824.0;
}

const sin_table: [65536]f32 = blk: {
    @setEvalBranchQuota(10_000_000);
    var t: [65536]f32 = undefined;
    for (&t, 0..) |*v, i| {
        v.* = @floatCast(@sin(@as(f64, @floatFromInt(i)) * std.math.pi * 2.0 / 65536.0));
    }
    break :blk t;
};

/// Float-to-int conversion with x86 `cvttss2si` semantics: out-of-range and
/// NaN inputs produce the integer indefinite value instead of trapping.
inline fn truncI32(v: f32) i32 {
    if (!(v >= -2147483648.0 and v < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(v);
}

inline fn tableAt(i: i32) f32 {
    return sin_table[@as(u16, @truncate(@as(u32, @bitCast(i))))];
}

/// Bedrock's lookup-table sine (`mce::Math::sin`).
pub inline fn mcSin(v: f32) f32 {
    return tableAt(truncI32(v * 10430.378));
}

/// Bedrock's lookup-table cosine. The scaled angle is rounded to f32 before
/// the quarter-turn offset is added.
pub inline fn mcCos(v: f32) f32 {
    const scaled: f32 = v * 10430.378;
    return tableAt(truncI32(scaled + 16384.0));
}

/// Correctly rounded `sinf`, evaluated in f64 and rounded once.
pub inline fn sinf(v: f32) f32 {
    return @floatCast(@sin(@as(f64, v)));
}

/// Correctly rounded `cosf`, evaluated in f64 and rounded once.
pub inline fn cosf(v: f32) f32 {
    return @floatCast(@cos(@as(f64, v)));
}

/// `previous + wrapDegrees(current - previous)` in f32.
pub fn wrappedAngle(previous: f32, current: f32) f32 {
    var delta = @rem(current - previous + 180, 360);
    if (delta < 0) delta += 360;
    return delta + -180 + previous;
}

pub const float_epsilon: f32 = 1.1920929e-7;

test "trig table matches the vanilla index rules" {
    try std.testing.expectEqual(@as(f32, 0), mcSin(0));
    try std.testing.expectEqual(@as(f32, 1), mcCos(0));
    try std.testing.expectEqual(sin_table[16384], mcSin(std.math.pi / 2.0));
    // Negative angles truncate toward zero before wrapping.
    var bits: u32 = @bitCast(@as(f32, -7));
    const stop: u32 = @bitCast(@as(f32, -6.99));
    while (bits > stop) : (bits -= 7) {
        const angle: f32 = @bitCast(bits);
        const scaled: f32 = angle * 10430.378;
        try std.testing.expectEqual(tableAt(@intFromFloat(scaled + 16384)), mcCos(angle));
        try std.testing.expectEqual(tableAt(@intFromFloat(scaled)), mcSin(angle));
    }
}

test "out-of-range trig indices do not trap" {
    try std.testing.expectEqual(sin_table[0], mcSin(1e30));
    try std.testing.expectEqual(sin_table[0], mcSin(-1e30));
    try std.testing.expectEqual(sin_table[0], mcCos(std.math.nan(f32)));
}

test "integer floor and ceil match libm" {
    const cases = [_]f32{ 0, -0.0, 0.5, -0.5, 1, -1, 1.0000001, -1.0000001, 63.999996, -64.00001, 16777216, -16777216, 2147483520, -2147483648, 1e-30, -1e-30 };
    for (cases) |v| {
        try std.testing.expectEqual(@as(i32, @intFromFloat(@floor(v))), floorI(v));
        try std.testing.expectEqual(@as(i32, @intFromFloat(@ceil(v))), ceilI(v));
    }
    var prng: std.Random.DefaultPrng = .init(1);
    for (0..100_000) |_| {
        const v = (prng.random().float(f32) - 0.5) * 2e6;
        try std.testing.expectEqual(@as(i32, @intFromFloat(@floor(v))), floorI(v));
        try std.testing.expectEqual(@as(i32, @intFromFloat(@ceil(v))), ceilI(v));
    }
}

test "wrapped angle" {
    try std.testing.expectEqual(@as(f32, 190), wrappedAngle(170, -170));
    try std.testing.expectEqual(@as(f32, -10), wrappedAngle(0, 350));
    try std.testing.expectEqual(@as(f32, 45), wrappedAngle(0, 45));
}
