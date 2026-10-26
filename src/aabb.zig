const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;
const Axis = math.Axis;

pub const AABB = extern struct {
    min: Vec3,
    max: Vec3,

    pub const unit: AABB = .init(0, 0, 0, 1, 1, 1);

    pub inline fn init(x0: f32, y0: f32, z0: f32, x1: f32, y1: f32, z1: f32) AABB {
        return .{ .min = .init(x0, y0, z0), .max = .init(x1, y1, z1) };
    }

    pub inline fn translate(b: AABB, v: Vec3) AABB {
        return .{ .min = b.min.add(v), .max = b.max.add(v) };
    }

    pub fn extend(b: AABB, v: Vec3) AABB {
        var r = b;
        inline for (.{ "x", "y", "z" }) |f| {
            const d = @field(v, f);
            if (d < 0) {
                @field(r.min, f) += d;
            } else if (d > 0) {
                @field(r.max, f) += d;
            }
        }
        return r;
    }

    pub inline fn grow(b: AABB, d: f32) AABB {
        return b.growVec(.init(d, d, d));
    }

    pub inline fn growVec(b: AABB, d: Vec3) AABB {
        return .{ .min = b.min.sub(d), .max = b.max.add(d) };
    }

    pub inline fn extendDown(b: AABB, d: f32) AABB {
        var r = b;
        r.min.y -= d;
        return r;
    }

    pub inline fn extendUp(b: AABB, d: f32) AABB {
        var r = b;
        r.max.y += d;
        return r;
    }

    pub inline fn intersects(a: AABB, o: AABB) bool {
        const e: f32 = 1e-5;
        return o.max.x - a.min.x > e and a.max.x - o.min.x > e and
            o.max.y - a.min.y > e and a.max.y - o.min.y > e and
            o.max.z - a.min.z > e and a.max.z - o.min.z > e;
    }

    pub inline fn isDegenerate(b: AABB) bool {
        return !(b.min.x < b.max.x and b.min.y < b.max.y and b.min.z < b.max.z and
            b.min.isFinite() and b.max.isFinite());
    }

    pub inline fn isFinite(b: AABB) bool {
        return b.min.isFinite() and b.max.isFinite();
    }

    pub inline fn bottomCenter(b: AABB) Vec3 {
        return .init((b.min.x + b.max.x) * 0.5, b.min.y, (b.min.z + b.max.z) * 0.5);
    }

    pub fn format(b: AABB, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("[{f} -> {f}]", .{ b.min, b.max });
    }
};

const contact_epsilon: f32 = 1e-6;

pub const Clip = struct {
    clipped: Vec3,
    depenetrating: Vec3,
    axis: Axis = .x,
    penetration: f32 = 0,
};

pub fn clipCollide(stationary: AABB, moving: AABB, vel: Vec3) Clip {
    var r: Clip = .{ .clipped = vel, .depenetrating = vel };
    if (stationary.isDegenerate()) return r;

    var pen: [3]f32 = undefined;
    var signed: [3]f32 = undefined;
    var normal: [3]f32 = undefined;
    var separating: u32 = 0;
    var sep_axis: usize = 0;
    var result_pen: f32 = std.math.floatMax(f32) - 1;

    const smin = [3]f32{ stationary.min.x, stationary.min.y, stationary.min.z };
    const smax = [3]f32{ stationary.max.x, stationary.max.y, stationary.max.z };
    const mmin = [3]f32{ moving.min.x, moving.min.y, moving.min.z };
    const mmax = [3]f32{ moving.max.x, moving.max.y, moving.max.z };

    for (0..3) |i| {
        var min_pen = mmax[i] - smin[i];
        var max_pen = smax[i] - mmin[i];
        if (@abs(min_pen) <= contact_epsilon) min_pen = 0;
        if (@abs(max_pen) <= contact_epsilon) max_pen = 0;
        const min_pos = @max(0, min_pen);
        const max_pos = @max(0, max_pen);

        if (min_pos == 0) {
            pen[i] = 0;
            signed[i] = min_pen;
            normal[i] = -1;
            separating += 1;
            sep_axis = i;
        } else if (max_pos == 0) {
            pen[i] = 0;
            signed[i] = max_pen;
            normal[i] = 1;
            separating += 1;
            sep_axis = i;
        } else if (min_pos < max_pos) {
            pen[i] = min_pos;
            signed[i] = min_pos;
            normal[i] = -1;
        } else {
            pen[i] = max_pos;
            signed[i] = max_pos;
            normal[i] = 1;
        }
        if (separating > 1) return r;
        result_pen = @min(result_pen, pen[i]);
    }

    const v = [3]f32{ vel.x, vel.y, vel.z };
    if (separating == 0) {
        r.penetration = result_pen;
        var best: usize = 0;
        for (1..3) |i| {
            if (pen[i] < pen[best]) best = i;
        }
        const desired = pen[best] * normal[best];
        const out = if (desired > 0) @max(desired, v[best]) else @min(desired, v[best]);
        r.depenetrating.set(@fromBackingInt(@intCast(best)), out);
        r.axis = @fromBackingInt(@intCast(best));
        return r;
    }

    const swept = signed[sep_axis] - (normal[sep_axis] * v[sep_axis]);
    if (swept <= 0) return r;
    const resolved = signed[sep_axis] * normal[sep_axis];
    r.clipped.set(@fromBackingInt(@intCast(sep_axis)), resolved);
    r.depenetrating.set(@fromBackingInt(@intCast(sep_axis)), resolved);
    return r;
}

const testing = std.testing;

test "clip stops a falling box on a floor" {
    const floor_box = AABB.init(0, 0, 0, 1, 1, 1);
    const player = AABB.init(0.2, 1.5, 0.2, 0.8, 3.3, 0.8);
    const c = clipCollide(floor_box, player, .init(0, -1, 0));
    try testing.expectEqual(@as(f32, -0.5), c.clipped.y);
}

test "clip ignores boxes separated on two axes" {
    const a = AABB.init(0, 0, 0, 1, 1, 1);
    const b = AABB.init(2, 2, 0.2, 3, 3, 0.8);
    const c = clipCollide(a, b, .init(-5, -5, 0));
    try testing.expectEqual(@as(f32, -5), c.clipped.x);
    try testing.expectEqual(@as(f32, -5), c.clipped.y);
}

test "contact within a micrometre snaps to zero" {
    const wall = AABB.init(1, 0, 0, 2, 1, 1);
    const player = AABB.init(0.4, 0, 0, 1 - 5e-7, 1, 1);
    const c = clipCollide(wall, player, .init(0.3, 0, 0));
    try testing.expectEqual(@as(f32, 0), c.clipped.x);
}

test "overlap depenetrates along the shallow axis" {
    const block = AABB.init(0, 0, 0, 1, 1, 1);
    const player = AABB.init(0.2, 0.9, 0.2, 0.8, 2.7, 0.8);
    const c = clipCollide(block, player, .init(0, -0.1, 0));
    try testing.expectEqual(Axis.y, c.axis);
    try testing.expect(c.depenetrating.y > 0);
    try testing.expectEqual(@as(f32, -0.1), c.clipped.y);
}

test "degenerate boxes never collide" {
    const flat = AABB.init(0, 0, 0, 1, 0, 1);
    const player = AABB.init(0.2, 0.5, 0.2, 0.8, 2.3, 0.8);
    const c = clipCollide(flat, player, .init(0, -1, 0));
    try testing.expectEqual(@as(f32, -1), c.clipped.y);
    try testing.expect(AABB.init(0, 0, 0, std.math.inf(f32), 1, 1).isDegenerate());
}
