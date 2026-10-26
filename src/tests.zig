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
    try testing.expectApproxEqAbs(@as(f32, (1 - 0.08) * 0.98), s.vel.y, 1e-6);
    var b: State = .{ .pos = .init(4.5, 0.2, 0.5), .vel = .init(0, -1, 0) };
    r = f.sim.tick(&b, &.{});
    try testing.expectApproxEqAbs(@as(f32, (0.75 - 0.08) * 0.98), b.vel.y, 1e-6);
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
    s.queueFireworkBoost();
    _ = f.sim.tick(&s, &.{});
    try testing.expectEqual(@as(u8, 0), s.glide_boost_ticks);
    try testing.expect(!s.firework_pending);
    s.queueFireworkBoost();
    const r = f.sim.tick(&s, &.{ .flags = .{ .start_gliding = true } });
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
    const liquid = @import("liquid.zig");
    try testing.expectEqual(@as(u32, 0x3dfae147), @as(u32, @bitCast(Simulator.max_consuming_impulse)));
    try testing.expectEqual(@as(u32, 0x3c8efa35), @as(u32, @bitCast(Simulator.deg_to_rad)));
    try testing.expectEqual(@as(u32, 0x3f051eb8), @as(u32, @bitCast(liquid.swim_air_probe)));
    try testing.expectEqual(@as(u32, 0x3ed70a3c), @as(u32, @bitCast(liquid.swim_liquid_probe)));
    try testing.expectEqual(@as(u32, 0xbf1170a4), @as(u32, @bitCast(Simulator.edge_drop)));
}

test "captured BDS wall contacts" {
    const cases = [_]struct { pos: Vec3, wall: AABB, vel: Vec3, axis: math.Axis, want: f32 }{
        .{ .pos = .init(186.61009, -59.580002, 4.5), .wall = .init(187, -61, 3, 188, -59, 6), .vel = .init(0.28, 0, 0), .axis = .x, .want = 186.7 },
        .{ .pos = .init(26.5, -59, 5.611176), .wall = .init(24, -60, 6, 29, -58, 7), .vel = .init(0, 0, 0.2584), .axis = .z, .want = 5.7 },
    };
    for (cases) |c| {
        const s: State = .{ .pos = c.pos };
        const box = s.boundingBox();
        const moved = box.translate(@import("aabb.zig").clipCollide(c.wall, box, c.vel).depenetrating);
        const center = moved.min.add(moved.max).scale(0.5);
        try testing.expectEqual(c.want, center.get(c.axis));
    }
}

test "contact epsilon does not shrink sweeps" {
    const clipCollide = @import("aabb.zig").clipCollide;
    const wall = AABB.init(-1, -1, -1, 0, 3, 3);
    for ([_]struct { gap: f32, blocked: bool }{ .{ .gap = -5e-7, .blocked = false }, .{ .gap = -2e-6, .blocked = true }, .{ .gap = 5e-7, .blocked = false } }) |c| {
        const box = AABB.init(c.gap, 0, 0, 0.6 + c.gap, 1.8, 0.6);
        const r = clipCollide(wall, box, .init(0, 0, 0.1));
        try testing.expectEqual(c.blocked, r.penetration > 0);
        try testing.expectEqual(c.blocked, r.depenetrating.x > 0);
    }
}

fn roundedContactWorld(map: *MapWorld, axis: math.Axis, sign: f32) !State {
    const stone: Block = .full(.default);
    const lo: i32 = if (sign > 0) 249 else -256;
    const hi: i32 = if (sign > 0) 255 else -250;
    const flo: i32 = if (sign > 0) 249 else -263;
    const fhi: i32 = if (sign > 0) 262 else -250;
    if (axis == .x) {
        try map.fill(gpa, .init(flo, 0, -6), .init(fhi, 0, 6), stone);
        try map.fill(gpa, .init(lo, 0, -6), .init(hi, 3, 6), stone);
    } else {
        try map.fill(gpa, .init(-6, 0, flo), .init(6, 0, fhi), stone);
        try map.fill(gpa, .init(-6, 0, lo), .init(6, 3, hi), stone);
    }
    var s: State = .{ .pos = .init(0.5, 1, 0.5), .on_ground = true };
    s.pos.set(axis, sign * 256.3);
    s.reported.pos = s.pos;
    return s;
}

fn other(axis: math.Axis) math.Axis {
    return if (axis == .x) .z else .x;
}

test "rounded contact seeds stay flush across re-anchoring" {
    for ([_]math.Axis{ .x, .z }) |axis| for ([_]f32{ -1, 1 }) |sign| {
        var map: MapWorld = .{};
        defer map.deinit(gpa);
        var s = try roundedContactWorld(&map, axis, sign);
        var sim: Simulator = .init(map.world(), .{ .policy = .vanilla });
        for (0..3) |_| {
            var p = s.pos;
            p.set(other(axis), p.get(other(axis)) + 0.01);
            s.setPosition(p);
            s.vel = .zero;
            s.vel.set(other(axis), 0.1);
            const r = sim.tick(&s, &.{ .reported_pos = s.pos });
            try testing.expectEqual(state_mod.Outcome.normal, r.outcome);
            try testing.expect(!r.collide_x and !r.collide_z and !s.penetrated_last_frame and !s.stuck_in_collider);
            try testing.expectEqual(sign * 256.3, s.pos.get(axis));
            try testing.expect(s.on_ground);
        }
    };
}

test "rounded contact recovery keeps real penetration" {
    for ([_]math.Axis{ .x, .z }) |axis| for ([_]f32{ -1, 1 }) |sign| {
        var map: MapWorld = .{};
        defer map.deinit(gpa);
        var s = try roundedContactWorld(&map, axis, sign);
        s.pos.set(axis, s.pos.get(axis) - sign * 0.005);
        var sim: Simulator = .init(map.world(), .{ .policy = .vanilla });
        const r = sim.tick(&s, &.{ .reported_pos = s.pos });
        try testing.expectEqual(state_mod.Outcome.normal, r.outcome);
        try testing.expect(s.penetrated_last_frame and (r.collide_x or r.collide_z));
    };
}

test "rounded contact recovery is independent of box order" {
    const boxes = [_]AABB{ .init(255, 0, 255, 256, 4, 258), .init(255, 0, 255, 258, 4, 256) };
    const reversed = [_]AABB{ boxes[1], boxes[0] };
    const s: State = .{ .pos = .init(256.3, 1, 256.3) };
    for ([_][]const AABB{ &boxes, &reversed }) |list| {
        const box = Simulator.recoverRoundedContacts(s.boxAt(s.pos), s.pos, list);
        try testing.expect(box.min.eql(.init(256, 1, 256)));
        const c = box.min.add(box.max).scale(0.5);
        try testing.expect(c.x == s.pos.x and c.z == s.pos.z);
    }
}

test "rounded contact recovery waits for loaded world data" {
    var map: MapWorld = .{};
    defer map.deinit(gpa);
    var s = try roundedContactWorld(&map, .x, 1);
    map.loaded_max = .init(200, 400, 400);
    var sim: Simulator = .init(map.world(), .{ .policy = .vanilla });
    try testing.expectEqual(state_mod.Outcome.unloaded, sim.tick(&s, &.{ .reported_pos = s.pos }).outcome);
    try testing.expect(!s.shape.valid);
    map.loaded_max = .init(std.math.maxInt(i32), std.math.maxInt(i32), std.math.maxInt(i32));
    s.vel = .init(0, -0.0784, 0.1);
    const r = sim.tick(&s, &.{ .reported_pos = s.pos });
    try testing.expect(r.outcome == .normal and !r.collide_x and !s.penetrated_last_frame);
}

test "native teleports and resizes rebuild endpoints without recovery" {
    for ([_]bool{ true, false }) |teleport| {
        var map: MapWorld = .{};
        defer map.deinit(gpa);
        var s = try roundedContactWorld(&map, .x, 1);
        var sim: Simulator = .init(map.world(), .{ .policy = .vanilla });
        _ = sim.tick(&s, &.{ .reported_pos = s.pos });
        s.pos.x = 256.3;
        s.vel = .zero;
        if (teleport) {
            s.queueTeleport(s.pos, 0);
            try testing.expectEqual(state_mod.Outcome.teleport, sim.tick(&s, &.{ .reported_pos = s.pos }).outcome);
        } else {
            s.size.height = 1.49;
            s.sneaking = true;
        }
        s.vel = .init(0, -0.0784, 0.1);
        const r = sim.tick(&s, &.{ .reported_pos = s.pos, .flags = .{ .sneak_down = !teleport } });
        try testing.expect(r.collide_x and s.penetrated_last_frame);
    }
}

test "rounded contact recovery does not erase new obstacles" {
    var map: MapWorld = .{};
    defer map.deinit(gpa);
    var s = try roundedContactWorld(&map, .x, 1);
    var removed: MapWorld = .{};
    defer removed.deinit(gpa);
    try removed.fill(gpa, .init(249, 0, -6), .init(262, 0, 6), .full(.default));
    var sim: Simulator = .init(removed.world(), .{ .policy = .vanilla });
    s.vel = .zero;
    _ = sim.tick(&s, &.{ .reported_pos = s.pos });
    s.pos.x = 256.3;
    s.pos.z = 0.5;
    s.vel = .init(0, -0.0784, 0.1);
    sim.world = map.world();
    const r = sim.tick(&s, &.{ .reported_pos = s.pos });
    try testing.expect(r.collide_x and s.penetrated_last_frame);
}

const shapes = [_][]const AABB{
    &.{AABB.unit},
    &.{AABB.init(0, 0, 0, 1, 0.5, 1)},
    &.{AABB.init(0, 0.5, 0, 1, 1, 1)},
    &.{ AABB.init(0, 0, 0, 1, 0.5, 1), AABB.init(0, 0.5, 0.5, 1, 1, 1) },
    &.{AABB.init(0.375, 0, 0.375, 0.625, 1.5, 0.625)},
    &.{AABB.init(0, 0, 0, 1, 0.0625, 1)},
    &.{AABB.init(0, 0, 0.8125, 1, 1, 1)},
};

fn randomBlock(r: std.Random) Block {
    const semantics = [_]Semantics{ .default, .ice, .slime, .honey_block, .soul_sand, .ladder, .cobweb_block, .sweet_berry_bush, .powder_snow, .scaffolding, .bed };
    return switch (r.uintLessThan(u8, 10)) {
        0 => .liquidBlock(.{ .kind = .water, .level = r.int(u3), .falling = r.boolean() }),
        1 => .liquidBlock(.{ .kind = .lava, .level = r.int(u3) }),
        2 => .{ .semantics = semantics[r.uintLessThan(usize, semantics.len)] },
        3 => .{ .liquid = .water_source, .bubble = if (r.boolean()) .up else .down },
        else => .{
            .shape = shapes[r.uintLessThan(usize, shapes.len)],
            .semantics = semantics[r.uintLessThan(usize, semantics.len)],
            .liquid = if (r.uintLessThan(u8, 6) == 0) Liquid.water_source else null,
            .flow_barrier = true,
            .solid_faces = @bitCast(r.int(u4)),
        },
    };
}

const Liquid = world_mod.Liquid;

fn overlapsWorld(map: *MapWorld, box: AABB) bool {
    var x = math.floorI(box.min.x);
    while (x <= math.floorI(box.max.x)) : (x += 1) {
        var y = math.floorI(box.min.y) - 1;
        while (y <= math.floorI(box.max.y)) : (y += 1) {
            var z = math.floorI(box.min.z);
            while (z <= math.floorI(box.max.z)) : (z += 1) {
                const b = map.world().block(.init(x, y, z)) orelse continue;
                for (b.shape) |local| {
                    if (local.translate(BlockPos.init(x, y, z).vec()).intersects(box)) return true;
                }
            }
        }
    }
    return false;
}

fn chaoticInput(r: std.Random) Input {
    var in: Input = .{
        .move = .{ .x = r.float(f32) * 2.4 - 1.2, .y = r.float(f32) * 2.4 - 1.2 },
        .move_is_raw = r.boolean(),
        .rotation = .{ .pitch = r.float(f32) * 180 - 90, .yaw = r.float(f32) * 720 - 360, .head_yaw = 0 },
        .flags = @bitCast(r.int(u32) & r.int(u32) & r.int(u32)),
    };
    if (r.uintLessThan(u8, 10) == 0) in.item_use_modifier = r.float(f32);
    switch (r.uintLessThan(u8, 60)) {
        0 => in.move.x = std.math.nan(f32),
        1 => in.rotation.yaw = std.math.inf(f32),
        2 => in.item_use_modifier = 2,
        else => {},
    }
    return in;
}

test "property: chaotic input never corrupts state or enters geometry" {
    var prng: std.Random.DefaultPrng = .init(0x52495054);
    const r = prng.random();
    var checked: usize = 0;
    for (0..120) |_| {
        var map: MapWorld = .{};
        defer map.deinit(gpa);
        try map.fill(gpa, .init(-8, -1, -8), .init(8, -1, 8), .full(.default));
        for (0..60) |_| {
            try map.put(gpa, .init(r.intRangeAtMost(i32, -6, 6), r.intRangeAtMost(i32, 0, 4), r.intRangeAtMost(i32, -6, 6)), randomBlock(r));
        }
        var sim: Simulator = .init(map.world(), .{ .policy = if (r.boolean()) .vanilla else .hardened });
        var s: State = .{ .pos = .init(r.float(f32) * 4 - 2, r.float(f32) * 4, r.float(f32) * 4 - 2) };
        s.equipment = .{ .elytra = r.boolean(), .riptide = r.uintAtMost(u8, 3), .leather_boots = r.boolean(), .depth_strider = r.uintAtMost(u8, 3) };
        for (0..80) |_| {
            const in = chaoticInput(r);
            if (r.uintLessThan(u8, 30) == 0) s.queueMotion(.init(r.float(f32) * 2 - 1, r.float(f32) * 2 - 1, r.float(f32) * 2 - 1));
            s.riptide_ready = r.uintLessThan(u8, 10) == 0;
            const before = s;
            const was_inside = overlapsWorld(&map, s.boundingBox());
            const res = sim.tick(&s, &in);
            try testing.expect(s.isValid());
            if (!in.isValid()) {
                try testing.expectEqual(state_mod.Outcome.invalid_input, res.outcome);
                try testing.expect(std.meta.eql(before, s));
                continue;
            }
            if (res.outcome == .normal and !was_inside and !res.mechanics.pose_change) {
                checked += 1;
                if (overlapsWorld(&map, s.boundingBox())) {
                    std.debug.print("entered geometry: before={f} after={f} box={f}\n", .{ before.pos, s.pos, s.boundingBox() });
                    return error.TestEnteredGeometry;
                }
            }
        }
    }
    try testing.expect(checked > 5000);
}

test "property: replays of chaotic input are bit-identical" {
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    var map: MapWorld = .{};
    defer map.deinit(gpa);
    try map.fill(gpa, .init(-8, -1, -8), .init(8, -1, 8), .full(.ice));
    for (0..80) |_| try map.put(gpa, .init(r.intRangeAtMost(i32, -6, 6), r.intRangeAtMost(i32, 0, 3), r.intRangeAtMost(i32, -6, 6)), randomBlock(r));
    var inputs: [300]Input = undefined;
    for (&inputs) |*in| in.* = chaoticInput(r);
    var sim: Simulator = .init(map.world(), .{ .policy = .hardened });
    var a: [300]replay.Frame = undefined;
    var b: [300]replay.Frame = undefined;
    const initial: State = .{ .pos = .init(0.5, 2, 0.5), .equipment = .{ .elytra = true } };
    _ = replay.run(&sim, initial, &inputs, &a);
    var other_sim: Simulator = .init(map.world(), .{ .policy = .hardened });
    _ = replay.run(&other_sim, initial, &inputs, &b);
    for (a, b) |x, y| {
        try testing.expect(std.meta.eql(x.state, y.state));
        try testing.expect(std.meta.eql(x.result, y.result));
    }
}

test "invalid block semantics are reported, not simulated" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.map.put(gpa, .init(0, -1, 0), .full(.{ .friction = std.math.nan(f32) }));
    f.init(.vanilla);
    var s = standing(.init(0.5, 0, 0.5));
    const before = s;
    try testing.expectEqual(state_mod.Outcome.invalid_world, f.sim.tick(&s, &.{}).outcome);
    try testing.expect(s.pos.eql(before.pos));
}

test "coordinates at the i32 edge are rejected without overflow" {
    var f: Fixture = .{};
    defer f.deinit();
    f.init(.vanilla);
    for ([_]Vec3{ .init(-2147483648.0, 64, 0), .init(0, -2147483648.0, 0), .init(2147483520.0, 64, 0) }) |pos| {
        var s: State = .{ .pos = pos };
        try testing.expectEqual(state_mod.Outcome.query_limit, f.sim.tick(&s, &.{}).outcome);
    }
}

test "huge sweeps do not overflow the cell count" {
    var f: Fixture = .{};
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .pos = .init(-1.0e9, -1.0e9, 0), .vel = .init(2.0e9, 2.0e9, 0) };
    try testing.expectEqual(state_mod.Outcome.query_limit, f.sim.tick(&s, &.{}).outcome);
}

test "an unloaded pose tick clears the queued stuck speed" {
    var f: Fixture = .{ .map = .{ .loaded_min = .init(-16, -64, -16), .loaded_max = .init(15, 319, 15) } };
    defer f.deinit();
    f.init(.vanilla);
    var s: State = .{ .pos = .init(15.9, 64, 0.5), .stuck_speed = .init(0.25, 0.05, 0.25) };
    try testing.expectEqual(state_mod.Outcome.unloaded, f.sim.tick(&s, &.{}).outcome);
    try testing.expect(s.stuck_speed.eql(.zero));
}

test "divergence search tolerates different lengths" {
    const r: state_mod.Result = .{ .outcome = .normal };
    const a = [_]state_mod.Result{ r, r, r };
    try testing.expectEqual(@as(?usize, 2), replay.firstDivergence(&a, a[0..2], 0));
    try testing.expectEqual(@as(?usize, null), replay.firstDivergence(&a, &a, 0));
}

fn extreme(r: std.Random) f32 {
    const mag = std.math.pow(f32, 10, r.float(f32) * 38.5 - 2);
    return if (r.boolean()) mag else -mag;
}

test "property: extreme finite states never crash" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.floor(4, .full(.default));
    f.init(.hardened);
    var prng: std.Random.DefaultPrng = .init(0xE87);
    const r = prng.random();
    for (0..20_000) |_| {
        var s: State = .{
            .pos = .init(extreme(r), extreme(r), extreme(r)),
            .vel = .init(extreme(r), extreme(r), extreme(r)),
            .fall_distance = @abs(extreme(r)),
            .effects = .{ .jump_boost = r.int(i32), .levitation = if (r.boolean()) r.int(i32) else null },
            .equipment = .{ .swift_sneak = r.int(u8), .depth_strider = r.int(u8), .riptide = r.int(u8) },
        };
        if (r.boolean()) s.pos = .init(r.float(f32) * 6 - 3, r.float(f32) * 3, r.float(f32) * 6 - 3);
        if (r.boolean()) s.queueMotion(.init(extreme(r), extreme(r), extreme(r)));
        s.riptide_ready = r.boolean();
        const in: Input = .{
            .move = .{ .x = extreme(r), .y = extreme(r) },
            .move_is_raw = r.boolean(),
            .rotation = .{ .pitch = extreme(r), .yaw = extreme(r) },
            .reported_pos = .init(extreme(r), extreme(r), extreme(r)),
            .reported_vel = .init(extreme(r), extreme(r), extreme(r)),
            .flags = @bitCast(r.int(u32) & 0x3fffffff),
        };
        _ = f.sim.tick(&s, &in);
        try testing.expect(s.isValid());
        _ = f.sim.tick(&s, &.{});
        try testing.expect(s.isValid());
    }
}
