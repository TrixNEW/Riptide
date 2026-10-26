//! Optional per-stage physics trace for debugging divergences.
//!
//! Tracing is off unless `Simulator.trace` points at a `Trace`; the
//! disabled cost is one null check per stage.

const std = @import("std");
const Vec3 = @import("math.zig").Vec3;

pub const Stage = enum(u8) {
    input,
    teleport,
    motion,
    riptide_launch,
    liquid_flow,
    liquid_travel,
    glide,
    move_relative,
    climb,
    jump,
    stuck_speed,
    sneak_edge,
    collide,
    step,
    post_collision,
    gravity,
    friction,
    stand_on,
    inside_blocks,
    final,
};

pub const Event = struct {
    tick: u64,
    stage: Stage,
    pos: Vec3,
    vel: Vec3,
    on_ground: bool,
};

/// Fixed-capacity trace over a caller-owned buffer. Events past capacity
/// are counted in `dropped`.
pub const Trace = struct {
    events: []Event,
    len: usize = 0,
    dropped: usize = 0,
    tick: u64 = 0,

    pub fn init(buffer: []Event) Trace {
        return .{ .events = buffer };
    }

    pub fn reset(t: *Trace) void {
        t.len = 0;
        t.dropped = 0;
        t.tick = 0;
    }

    pub fn record(t: *Trace, stage: Stage, pos: Vec3, vel: Vec3, on_ground: bool) void {
        if (t.len == t.events.len) {
            t.dropped += 1;
            return;
        }
        t.events[t.len] = .{ .tick = t.tick, .stage = stage, .pos = pos, .vel = vel, .on_ground = on_ground };
        t.len += 1;
    }

    pub fn slice(t: *const Trace) []const Event {
        return t.events[0..t.len];
    }

    pub fn dump(t: *const Trace, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (t.slice()) |e| {
            try w.print("{d:>6} {s:<15} pos={f} vel={f} ground={}\n", .{ e.tick, @tagName(e.stage), e.pos, e.vel, e.on_ground });
        }
        if (t.dropped != 0) try w.print("({d} events dropped)\n", .{t.dropped});
    }
};

test "trace drops past capacity" {
    var buf: [2]Event = undefined;
    var t: Trace = .init(&buf);
    t.record(.input, .zero, .zero, false);
    t.record(.final, .zero, .zero, true);
    t.record(.final, .zero, .zero, true);
    try std.testing.expectEqual(@as(usize, 2), t.len);
    try std.testing.expectEqual(@as(usize, 1), t.dropped);
}
