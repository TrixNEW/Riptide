//! Scenario tests for the simulator. Expected values come from BedSim's
//! tests or from hand-derived vanilla arithmetic noted per test.

const std = @import("std");
const testing = std.testing;
const math = @import("math.zig");
const world_mod = @import("world.zig");
const state_mod = @import("state.zig");
const Simulator = @import("Simulator.zig");
const replay = @import("replay.zig");
const AABB = @import("aabb.zig").AABB;

const Vec3 = math.Vec3;
const Block = world_mod.Block;
const BlockPos = world_mod.BlockPos;
const MapWorld = world_mod.MapWorld;
const Semantics = world_mod.Semantics;
const State = state_mod.State;
const Input = state_mod.Input;

const gpa = testing.allocator;

const Fixture = struct {
    map: MapWorld = .{},
    sim: Simulator = undefined,

    fn init(f: *Fixture, policy: state_mod.Policy) void {
        f.sim = .init(f.map.world(), .{ .policy = policy });
    }

    fn deinit(f: *Fixture) void {
        f.map.deinit(gpa);
    }

    /// A stone floor whose top is y = 0 over [-r, r] in x and z.
    fn floor(f: *Fixture, r: i32, b: Block) !void {
        try f.map.fill(gpa, .init(-r, -1, -r), .init(r, -1, r), b);
    }
};

fn standing(pos: Vec3) State {
    var s: State = .{ .pos = pos, .on_ground = true };
    s.reported.pos = pos;
    return s;
}

test "falling uses vanilla gravity and drag" {
    var f: Fixture = .{};
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .pos = .init(0.5, 100, 0.5) };
    const r = f.sim.tick(&s, &.{});
    try testing.expectEqual(state_mod.Outcome.normal, r.outcome);
    try testing.expectEqual(@as(f32, (0 - 0.08) * 0.98), s.vel.y);
    // Terminal velocity emerges from (v - 0.08) * 0.98 and is never clamped.
    for (0..1000) |_| _ = f.sim.tick(&s, &.{});
    try testing.expectApproxEqAbs(@as(f32, -3.92), s.vel.y, 1e-4);
}

test "walking on stone reaches the vanilla steady state" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.floor(64, .full(.default));
    f.init(.vanilla);
    var s = standing(.init(0.5, 0, 0.5));
    const input: Input = .{ .move = .{ .y = 1 } };
    for (0..60) |_| _ = f.sim.tick(&s, &input);
    try testing.expect(s.on_ground);
    try testing.expectEqual(@as(f32, 0), s.pos.y);
    // v = (v + 0.1 * 0.98) * 0.546 converges to 0.1178...
    try testing.expectApproxEqAbs(@as(f32, 0.098 * 0.546 / (1 - 0.546)), s.vel.z, 1e-5);
    try testing.expectEqual(@as(f32, 0), s.vel.x);
}

test "ice keeps more momentum than stone" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.floor(64, .full(.ice));
    f.init(.vanilla);
    var s = standing(.init(0.5, 0, 0.5));
    s.vel.z = 0.3;
    _ = f.sim.tick(&s, &.{});
    const drag = @as(f32, 0.91) * @as(f32, 0.98);
    try testing.expectEqual(@as(f32, 0.3) * drag, s.vel.z);
}

test "jump reaches its apex and lands on the same block" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.floor(8, .full(.default));
    f.init(.vanilla);
    var s = standing(.init(0.5, 0, 0.5));
    var r = f.sim.tick(&s, &.{ .flags = .{ .start_jumping = true, .jumping = true } });
    try testing.expect(r.mechanics.jump);
    try testing.expectEqual(@as(f32, 0.42), s.mov.y);
    var apex: f32 = 0;
    var ticks: u32 = 1;
    while (!s.on_ground) : (ticks += 1) {
        r = f.sim.tick(&s, &.{});
        apex = @max(apex, s.pos.y);
        try testing.expect(ticks < 40);
    }
    try testing.expectEqual(@as(f32, 0), s.pos.y);
    try testing.expectApproxEqAbs(@as(f32, 1.2522), apex, 1e-3);
    try testing.expectEqual(@as(u32, 12), ticks);
}

test "jump delay blocks a held re-jump for ten ticks" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.floor(8, .full(.default));
    f.init(.vanilla);
    var s = standing(.init(0.5, 0, 0.5));
    _ = f.sim.tick(&s, &.{ .flags = .{ .start_jumping = true, .jumping = true } });
    try testing.expectEqual(@as(u8, 9), s.jump_delay);
}

test "jump boost uses a zero-based amplifier" {
    var f: Fixture = .{};
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .effects = .{ .jump_boost = 0 } };
    _ = f.sim.tick(&s, &.{});
    try testing.expectApproxEqAbs(@as(f32, 0.52), s.jump_height, 1e-6);
}

test "levitation uses a zero-based amplifier" {
    var f: Fixture = .{};
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .effects = .{ .levitation = 0 }, .has_gravity = false };
    _ = f.sim.tick(&s, &.{});
    try testing.expectApproxEqAbs(@as(f32, 0.01), s.vel.y, 1e-6);
}

test "slow falling only changes gravity while descending" {
    var f: Fixture = .{};
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .pos = .init(0, 50, 0), .vel = .init(0, 0.2, 0), .effects = .{ .slow_falling = true } };
    _ = f.sim.tick(&s, &.{});
    try testing.expectApproxEqAbs(@as(f32, (0.2 - 0.08) * 0.98), s.vel.y, 1e-6);
    s.vel.y = -0.2;
    _ = f.sim.tick(&s, &.{});
    try testing.expectApproxEqAbs(@as(f32, (-0.2 - 0.01) * 0.98), s.vel.y, 1e-6);
}

test "tiny velocity is not discarded prematurely" {
    var f: Fixture = .{};
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .pos = .init(0, 50, 0), .vel = .init(2e-7, 0, 0), .has_gravity = false };
    _ = f.sim.tick(&s, &.{});
    try testing.expect(s.vel.x != 0);
}

test "steps up a slab but not a full block" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.floor(8, .full(.default));
    const slab = [_]AABB{.init(0, 0, 0, 1, 0.5, 1)};
    try f.map.put(gpa, .init(0, 0, 2), .{ .shape = &slab });
    try f.map.put(gpa, .init(2, 0, 2), .full(.default));
    f.init(.vanilla);

    var s = standing(.init(0.5, 0, 1.5));
    s.vel.z = 0.3;
    const r = f.sim.tick(&s, &.{});
    try testing.expect(r.mechanics.step);
    try testing.expectEqual(@as(f32, 0.5), s.pos.y);

    var w = standing(.init(2.5, 0, 1.5));
    w.vel.z = 0.3;
    _ = f.sim.tick(&w, &.{});
    try testing.expectEqual(@as(f32, 0), w.pos.y);
    try testing.expect(w.collide_z);
    try testing.expectEqual(@as(f32, 1.7), w.pos.z);
}

test "sneaking stops at a ledge" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.map.put(gpa, .init(0, -1, 0), .full(.default));
    f.init(.vanilla);
    var s = standing(.init(0.5, 0, 0.5));
    s.sneaking = true;
    s.size.height = s.size.sneaking_height;
    const input: Input = .{ .move = .{ .y = 1 }, .flags = .{ .sneak_down = true, .sneaking = true } };
    for (0..40) |_| _ = f.sim.tick(&s, &input);
    try testing.expect(s.on_ground);
    try testing.expectEqual(@as(f32, 0), s.pos.y);
    // The 0.025 inset lets the box overhang the edge by just under 0.325.
    try testing.expect(s.pos.z < 1.33);
}

test "edge protection requires ground" {
    var f: Fixture = .{};
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .pos = .init(0.5, 10, 0.5), .sneaking = true, .vel = .init(0.5, 0, 0) };
    s.size.height = s.size.sneaking_height;
    _ = f.sim.tick(&s, &.{});
    try testing.expect(s.mov.x == 0.5);
}

test "cobweb queues its multiplier for the next move" {
    var f: Fixture = .{};
    defer f.deinit();
    const pos: BlockPos = .init(32, 64, -24);
    try f.map.put(gpa, pos, .{ .semantics = .cobweb_block });
    f.init(.vanilla);
    var s: State = .{ .pos = .init(32.5, 64, -23.5), .has_gravity = false };
    const r = f.sim.tick(&s, &.{});
    try testing.expect(r.mechanics.cobweb);
    try testing.expect(s.stuck_speed.eql(.init(0.25, 0.05, 0.25)));
    s.vel = .init(1, 1, 1);
    _ = f.sim.tick(&s, &.{});
    try testing.expectEqual(@as(f32, 0.25), s.mov.x);
    try testing.expectEqual(@as(f32, 0), s.vel.x);
}

test "weaving softens webs only without other slowdown blocks" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.map.put(gpa, .init(0, 0, 0), .{ .semantics = .cobweb_block });
    f.init(.vanilla);
    var s: State = .{ .pos = .init(0.5, 0, 0.5), .has_gravity = false, .effects = .{ .weaving = true } };
    _ = f.sim.tick(&s, &.{});
    try testing.expect(s.stuck_speed.eql(.init(0.5, 0.25, 0.5)));
    try f.map.put(gpa, .init(0, 1, 0), .{ .semantics = .sweet_berry_bush });
    s = .{ .pos = .init(0.5, 0, 0.5), .has_gravity = false, .effects = .{ .weaving = true } };
    _ = f.sim.tick(&s, &.{});
    try testing.expect(s.stuck_speed.eql(.init(0.25, 0.05, 0.25)));
}

test "slime bounces and bed bounces three quarters" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.map.put(gpa, .init(0, -1, 0), .full(.slime));
    try f.map.put(gpa, .init(4, -1, 0), .full(.bed));
    f.init(.vanilla);
    var s: State = .{ .pos = .init(0.5, 0.2, 0.5), .vel = .init(0, -1, 0) };
    var r = f.sim.tick(&s, &.{});
    try testing.expect(r.mechanics.bounce);
    // Rebound 1.0 at impact, then gravity and drag.
    try testing.expectApproxEqAbs(@as(f32, (1 - 0.08) * 0.98), s.vel.y, 1e-6);
    var b: State = .{ .pos = .init(4.5, 0.2, 0.5), .vel = .init(0, -1, 0) };
    r = f.sim.tick(&b, &.{});
    try testing.expectApproxEqAbs(@as(f32, (0.75 - 0.08) * 0.98), b.vel.y, 1e-6);
    // Sneaking cancels the bounce.
    var n: State = .{ .pos = .init(0.5, 0.2, 0.5), .vel = .init(0, -1, 0), .sneaking = true };
    _ = f.sim.tick(&n, &.{ .flags = .{ .sneak_down = true } });
    try testing.expect(n.vel.y <= 0);
}

test "ladder climbing and sneak hold" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.floor(4, .full(.default));
    try f.map.put(gpa, .init(0, 0, 0), .{ .semantics = .ladder });
    try f.map.put(gpa, .init(0, 1, 0), .{ .semantics = .ladder });
    try f.map.put(gpa, .init(0, 0, 1), .full(.default));
    try f.map.put(gpa, .init(0, 1, 1), .full(.default));
    f.init(.vanilla);
    var s = standing(.init(0.5, 0, 0.5));
    const up: Input = .{ .flags = .{ .jumping = true } };
    _ = f.sim.tick(&s, &up);
    try testing.expectEqual(@as(f32, 0.2), s.mov.y);

    var h: State = .{ .pos = .init(0.5, 1.2, 0.5), .vel = .init(0, -0.5, 0), .sneaking = true };
    h.size.height = h.size.sneaking_height;
    _ = f.sim.tick(&h, &.{ .flags = .{ .sneak_down = true, .sneaking = true } });
    try testing.expectEqual(@as(f32, 0), h.mov.y);
}

test "water travel applies drag and buoyancy" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.map.fill(gpa, .init(-4, 0, -4), .init(4, 3, 4), .liquidBlock(.water_source));
    f.init(.vanilla);
    var s: State = .{ .pos = .init(0.5, 1, 0.5) };
    const r = f.sim.tick(&s, &.{});
    try testing.expect(r.mechanics.water);
    try testing.expectApproxEqAbs(@as(f32, -0.005), s.vel.y, 1e-7);
    try testing.expectEqual(@as(f32, 0), s.fall_distance);
}

test "lava travel halves velocity" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.map.fill(gpa, .init(-4, 0, -4), .init(4, 3, 4), .liquidBlock(.lava_source));
    f.init(.vanilla);
    var s: State = .{ .pos = .init(0.5, 1, 0.5), .vel = .init(0.2, 0, 0) };
    const r = f.sim.tick(&s, &.{});
    try testing.expect(r.mechanics.lava);
    try testing.expectApproxEqAbs(@as(f32, 0.1), s.vel.x, 1e-7);
    try testing.expectApproxEqAbs(@as(f32, -0.02), s.vel.y, 1e-7);
}

test "flowing water pushes the player downstream" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.floor(8, .full(.default));
    var x: i32 = -4;
    while (x <= 4) : (x += 1) {
        const level: u3 = @intCast(@min(7, x + 4));
        try f.map.put(gpa, .init(x, 0, 0), .liquidBlock(.{ .kind = .water, .level = level }));
    }
    f.init(.vanilla);
    var s = standing(.init(0.5, 0, 0.5));
    const r = f.sim.tick(&s, &.{});
    try testing.expect(r.mechanics.liquid_flow);
    try testing.expect(s.mov.x > 0);
}

test "hardened policy bounds a latched swim flag" {
    var f: Fixture = .{};
    defer f.deinit();
    f.init(.hardened);
    var s: State = .{ .pos = .init(0.5, 50, 0.5), .swimming = true };
    for (0..30) |_| _ = f.sim.tick(&s, &.{});
    // Without water contact the swim flag grants neither zero gravity nor
    // the collapsed hitbox.
    try testing.expect(!s.swimPose());
    try testing.expect(s.vel.y < -0.5);
}

test "vanilla policy trusts the swim flag" {
    var f: Fixture = .{};
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .pos = .init(0.5, 50, 0.5), .swimming = true };
    _ = f.sim.tick(&s, &.{});
    try testing.expect(s.swimPose());
    try testing.expectEqual(@as(f32, 0), s.vel.y);
}

test "instant teleport" {
    var f: Fixture = .{};
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .pos = .init(0, 70, 0), .vel = .init(1, 1, 1) };
    s.queueTeleport(.init(12, 63, -4), 0);
    const r = f.sim.tick(&s, &.{});
    try testing.expectEqual(state_mod.Outcome.teleport, r.outcome);
    try testing.expect(s.pos.eql(.init(12, 63, -4)));
    try testing.expect(s.vel.eql(.zero));
    try testing.expectEqual(@as(f32, 0), s.fall_distance);
    try testing.expect(s.teleport == null);
    try testing.expectEqual(state_mod.Outcome.normal, f.sim.tick(&s, &.{}).outcome);
}

test "smoothed teleport interpolates then snaps" {
    var f: Fixture = .{};
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .pos = .init(0, 64, 0), .has_gravity = false };
    s.queueTeleport(.init(3, 64, 0), 2);
    _ = f.sim.tick(&s, &.{});
    try testing.expectEqual(@as(f32, 1), s.pos.x);
    _ = f.sim.tick(&s, &.{});
    try testing.expectEqual(@as(f32, 2), s.pos.x);
    try testing.expectEqual(state_mod.Outcome.teleport, f.sim.tick(&s, &.{}).outcome);
    try testing.expectEqual(@as(f32, 3), s.pos.x);
    try testing.expectEqual(state_mod.Outcome.normal, f.sim.tick(&s, &.{}).outcome);
}

test "queued motion replaces velocity once" {
    var f: Fixture = .{};
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .pos = .init(0, 64, 0), .has_gravity = false };
    s.queueMotion(.init(0.4, 0, 0));
    const r = f.sim.tick(&s, &.{});
    try testing.expect(r.mechanics.motion);
    try testing.expectEqual(@as(f32, 0.4), s.mov.x);
    try testing.expect(s.pending_motion == null);
}

test "motion applies while gliding" {
    var f: Fixture = .{};
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .pos = .init(0, 64, 0), .gliding = true, .equipment = .{ .elytra = true } };
    s.queueMotion(.init(0, 1, 0));
    const r = f.sim.tick(&s, &.{ .flags = .{} });
    try testing.expect(r.mechanics.glide and r.mechanics.motion);
    try testing.expect(s.mov.y > 0.9);
}

test "unloaded world leaves position untouched" {
    var f: Fixture = .{ .map = .{ .loaded_min = .init(-16, -64, -16), .loaded_max = .init(15, 319, 15) } };
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .pos = .init(15.9, 64, 0.5), .vel = .init(0.5, 0, 0) };
    const r = f.sim.tick(&s, &.{});
    try testing.expectEqual(state_mod.Outcome.unloaded, r.outcome);
    try testing.expectEqual(@as(f32, 15.9), s.pos.x);
    try testing.expect(s.vel.eql(.zero));
}

test "a chunk boundary inside the sweep is unloaded" {
    var f: Fixture = .{ .map = .{ .loaded_min = .init(-16, -64, -16), .loaded_max = .init(15, 319, 15) } };
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .pos = .init(14.5, 64, 0.5), .vel = .init(2, 0, 0) };
    try testing.expectEqual(state_mod.Outcome.unloaded, f.sim.tick(&s, &.{}).outcome);
    try testing.expectEqual(@as(f32, 14.5), s.pos.x);
}

test "invalid input is rejected without mutation" {
    var f: Fixture = .{};
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .pos = .init(1, 2, 3) };
    const before = s;
    const bad: Input = .{ .move = .{ .x = std.math.nan(f32) } };
    try testing.expectEqual(state_mod.Outcome.invalid_input, f.sim.tick(&s, &bad).outcome);
    try testing.expect(std.meta.eql(before, s));
    const bad_mod: Input = .{ .item_use_modifier = 1.5 };
    try testing.expectEqual(state_mod.Outcome.invalid_input, f.sim.tick(&s, &bad_mod).outcome);
    s.vel.x = std.math.inf(f32);
    try testing.expectEqual(state_mod.Outcome.invalid_input, f.sim.tick(&s, &.{}).outcome);
}

test "extreme velocity hits the query limit instead of scanning" {
    var f: Fixture = .{};
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .pos = .init(0, 64, 0) };
    s.queueMotion(.init(1e6, 1e6, 1e6));
    try testing.expectEqual(state_mod.Outcome.query_limit, f.sim.tick(&s, &.{}).outcome);
    try testing.expect(s.vel.eql(.zero));
    try testing.expectEqual(state_mod.Outcome.normal, f.sim.tick(&s, &.{}).outcome);
}

test "extreme coordinates are rejected safely" {
    var f: Fixture = .{};
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .pos = .init(3e9, 64, 0) };
    try testing.expectEqual(state_mod.Outcome.query_limit, f.sim.tick(&s, &.{}).outcome);
    s = .{ .pos = .init(0, 64, 0), .rotation = .{ .yaw = 1e30, .pitch = -1e30 } };
    _ = f.sim.tick(&s, &.{ .move = .{ .y = 1 }, .rotation = .{ .yaw = 3e38 } });
    try testing.expect(s.isValid());
}

test "creative and flying are client authoritative" {
    var f: Fixture = .{};
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .game_mode = .creative };
    const r = f.sim.tick(&s, &.{ .reported_pos = .init(5, 6, 7), .reported_vel = .init(0, 1, 0) });
    try testing.expectEqual(state_mod.Outcome.client_authoritative, r.outcome);
    try testing.expect(s.pos.eql(.init(5, 6, 7)));
}

test "crouching under a low ceiling keeps the sneak pose" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.floor(4, .full(.default));
    try f.map.put(gpa, .init(0, 1, 0), .{ .shape = &[_]AABB{.init(0, 0.6, 0, 1, 1, 1)} });
    f.init(.vanilla);
    var s = standing(.init(0.5, 0, 0.5));
    s.sneaking = true;
    s.size.height = s.size.sneaking_height;
    const r = f.sim.tick(&s, &.{ .flags = .{ .stop_sneaking = true } });
    try testing.expectEqual(state_mod.Outcome.normal, r.outcome);
    try testing.expect(s.sneaking);
    try testing.expectEqual(s.size.sneaking_height, s.size.height);
}

test "raw input is normalised before slowdowns" {
    var f: Fixture = .{};
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .pos = .init(0, 64, 0) };
    const r = f.sim.tick(&s, &.{ .move = .{ .x = 1, .y = 1 }, .move_is_raw = true, .flags = .{ .using_item = true } });
    const n: f32 = 1 / @sqrt(@as(f32, 2));
    try testing.expectEqual(n * Simulator.max_consuming_impulse, r.input_move.x);
    const clamped = f.sim.tick(&s, &.{ .move = .{ .x = 1, .y = 1 }, .flags = .{ .sneak_down = true } });
    try testing.expectEqual(@as(f32, 0.3), clamped.input_move.y);
}

test "firework boost needs an active glide" {
    var f: Fixture = .{};
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .pos = .init(0, 64, 0), .equipment = .{ .elytra = true } };
    _ = f.sim.tick(&s, &.{ .flags = .{ .firework_boost = true } });
    try testing.expectEqual(@as(u8, 0), s.glide_boost_ticks);
    const r = f.sim.tick(&s, &.{ .flags = .{ .start_gliding = true, .firework_boost = true } });
    try testing.expect(r.mechanics.glide_boost);
    try testing.expectEqual(@as(u8, 19), s.glide_boost_ticks);
    var boosted: u32 = 1;
    while (s.glide_boost_ticks > 0) : (boosted += 1) {
        try testing.expect(f.sim.tick(&s, &.{}).mechanics.glide_boost);
    }
    try testing.expectEqual(@as(u32, 20), boosted);
    try testing.expect(!f.sim.tick(&s, &.{}).mechanics.glide_boost);
}

test "glide fall distance rules" {
    var f: Fixture = .{};
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .pos = .init(0, 64, 0), .gliding = true, .equipment = .{ .elytra = true }, .fall_distance = 5, .vel = .init(0, -0.4, 0) };
    _ = f.sim.tick(&s, &.{});
    try testing.expect(s.fall_distance < 1.5);
}

test "riptide launch requires a validated release" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.map.fill(gpa, .init(-4, 0, -4), .init(4, 3, 4), .liquidBlock(.water_source));
    f.init(.vanilla);
    var s: State = .{ .pos = .init(0.5, 1, 0.5), .equipment = .{ .riptide = 3 } };
    _ = f.sim.tick(&s, &.{ .flags = .{ .start_spin_attack = true } });
    try testing.expectEqual(@as(u8, 0), s.riptide_ticks);
    s.riptide_ready = true;
    const r = f.sim.tick(&s, &.{ .flags = .{ .start_spin_attack = true }, .rotation = .{ .pitch = -90 } });
    try testing.expect(r.mechanics.riptide);
    try testing.expect(s.mov.y > 2);
    try testing.expectEqual(@as(u8, 19), s.riptide_ticks);
    try testing.expect(!s.riptide_ready);
}

test "replay is deterministic and leaves the initial state untouched" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.floor(32, .full(.default));
    try f.map.put(gpa, .init(0, 0, 3), .{ .shape = &[_]AABB{.init(0, 0, 0, 1, 0.5, 1)} });
    f.init(.vanilla);
    const initial = standing(.init(0.5, 0, 0.5));
    var inputs: [80]Input = undefined;
    for (&inputs, 0..) |*in, i| in.* = .{
        .move = .{ .y = 1, .x = if (i % 7 == 0) 0.3 else 0 },
        .rotation = .{ .yaw = @floatFromInt(i * 3) },
        .flags = .{ .start_jumping = i % 13 == 0, .jumping = i % 13 < 3, .start_sprinting = i == 5 },
    };
    var a: [80]replay.Frame = undefined;
    var b: [80]replay.Frame = undefined;
    const end_a = replay.run(&f.sim, initial, &inputs, &a);
    const end_b = replay.run(&f.sim, initial, &inputs, &b);
    try testing.expect(std.meta.eql(end_a, end_b));
    var ra: [80]state_mod.Result = undefined;
    var rb: [80]state_mod.Result = undefined;
    for (a, b, &ra, &rb) |x, y, *p, *q| {
        p.* = x.result;
        q.* = y.result;
    }
    try testing.expectEqual(@as(?usize, null), replay.firstDivergence(&ra, &rb, 0));
    rb[40].pos.x += 1e-6;
    try testing.expectEqual(@as(?usize, 40), replay.firstDivergence(&ra, &rb, 0));
    try testing.expect(std.meta.eql(initial, standing(.init(0.5, 0, 0.5))));
}

test "trace records stages" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.floor(4, .full(.default));
    f.init(.vanilla);
    var events: [64]@import("trace.zig").Event = undefined;
    var t: @import("trace.zig").Trace = .init(&events);
    f.sim.trace = &t;
    var s = standing(.init(0.5, 0, 0.5));
    _ = f.sim.tick(&s, &.{ .move = .{ .y = 1 } });
    try testing.expect(t.len > 5);
    try testing.expectEqual(@import("trace.zig").Stage.input, t.slice()[0].stage);
    try testing.expectEqual(@import("trace.zig").Stage.final, t.slice()[t.len - 1].stage);
}

test "constants match the Go reference bit patterns" {
    // Bits printed by BedSim's Go constants on amd64.
    const liquid = @import("liquid.zig");
    try testing.expectEqual(@as(u32, 0x3dfae147), @as(u32, @bitCast(Simulator.max_consuming_impulse)));
    try testing.expectEqual(@as(u32, 0x3c8efa35), @as(u32, @bitCast(Simulator.deg_to_rad)));
    try testing.expectEqual(@as(u32, 0x3f051eb8), @as(u32, @bitCast(liquid.swim_air_probe)));
    try testing.expectEqual(@as(u32, 0x3ed70a3c), @as(u32, @bitCast(liquid.swim_liquid_probe)));
    try testing.expectEqual(@as(u32, 0xbf1170a4), @as(u32, @bitCast(Simulator.edge_drop)));
}
