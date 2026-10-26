const std = @import("std");
const math = @import("math.zig");
const world_mod = @import("world.zig");
const state_mod = @import("state.zig");
const contact = @import("contact.zig");
const Simulator = @import("Simulator.zig");

const Vec3 = math.Vec3;
const AABB = @import("aabb.zig").AABB;
const BlockPos = world_mod.BlockPos;
const Liquid = world_mod.Liquid;
const LiquidKind = world_mod.LiquidKind;
const State = state_mod.State;
const Error = Simulator.Error;
const cellAt = contact.cellAt;

pub fn liquidAt(sim: *Simulator, pos: BlockPos) Error!?Liquid {
    return (try sim.block(pos)).liquid;
}

fn intersects(box: AABB, pos: BlockPos, l: Liquid) bool {
    const y: f32 = @floatFromInt(pos.y);
    return box.max.y > y and box.min.y < y + l.height();
}

fn shrink(box: AABB, d: Vec3) AABB {
    var r: AABB = .{ .min = box.min.add(d), .max = box.max.sub(d) };
    inline for (.{ "x", "y", "z" }) |a| {
        if (@field(r.min, a) > @field(r.max, a)) {
            const mid = (@field(box.min, a) + @field(box.max, a)) * 0.5;
            @field(r.min, a) = mid;
            @field(r.max, a) = mid;
        }
    }
    return r;
}

pub fn collectTouching(sim: *Simulator, state: *const State) Error!void {
    const box = state.boundingBox();
    sim.scratch.water_len = try touching(sim, shrink(box, .init(0.001, 0.401, 0.001)), .water, &sim.scratch.water);
    sim.scratch.lava_len = try touching(sim, shrink(box, .init(0.1, 0.4, 0.1)), .lava, &sim.scratch.lava);
}

fn touching(sim: *Simulator, box: AABB, kind: LiquidKind, out: []BlockPos) Error!usize {
    const lo = try cellAt(box.min.x, box.min.y, box.min.z);
    const hi = try cellAt(box.max.x + 1, box.max.y + 1, box.max.z + 1);
    var n: usize = 0;
    var x = lo.x;
    while (x < hi.x) : (x += 1) {
        var y = lo.y;
        while (y < hi.y) : (y += 1) {
            var z = lo.z;
            while (z < hi.z) : (z += 1) {
                const pos: BlockPos = .init(x, y, z);
                const l = (try liquidAt(sim, pos)) orelse continue;
                if (l.kind != kind or !intersects(box, pos, l)) continue;
                if (n == out.len) return error.QueryLimit;
                out[n] = pos;
                n += 1;
            }
        }
    }
    return n;
}

fn containsAny(sim: *Simulator, box: AABB) Error!bool {
    const lo = try cellAt(box.min.x, box.min.y, box.min.z);
    const hi = try cellAt(@ceil(box.max.x), @ceil(box.max.y), @ceil(box.max.z));
    var x = lo.x;
    while (x < hi.x) : (x += 1) {
        var z = lo.z;
        while (z < hi.z) : (z += 1) {
            var y = lo.y;
            while (y < hi.y) : (y += 1) {
                const pos: BlockPos = .init(x, y, z);
                if (try liquidAt(sim, pos)) |l| if (intersects(box, pos, l)) return true;
            }
        }
    }
    return false;
}

const faces = [_]struct { dx: i32, dz: i32, face: Face }{
    .{ .dx = -1, .dz = 0, .face = .west },
    .{ .dx = 1, .dz = 0, .face = .east },
    .{ .dx = 0, .dz = -1, .face = .north },
    .{ .dx = 0, .dz = 1, .face = .south },
};

const Face = enum { west, east, north, south };

fn opposite(f: Face) Face {
    return switch (f) {
        .west => .east,
        .east => .west,
        .north => .south,
        .south => .north,
    };
}

fn faceClosed(sim: *Simulator, pos: BlockPos, f: Face) Error!bool {
    const s = (try sim.block(pos)).solid_faces;
    return switch (f) {
        .west => s.west,
        .east => s.east,
        .north => s.north,
        .south => s.south,
    };
}

pub fn applyFlow(sim: *Simulator, state: *State, cells: []const BlockPos, kind: LiquidKind) Error!void {
    if (cells.len == 0) return;
    var flow: Vec3 = .zero;
    for (cells) |pos| {
        const l = (try liquidAt(sim, pos)) orelse continue;
        if (l.kind != kind) continue;
        flow = flow.add(try cellFlow(sim, pos, l));
    }
    const len = flow.len();
    if (len >= 1e-4) {
        sim.mech.liquid_flow = true;
        const strength: f32 = if (kind == .lava) 0.0035 else 0.014;
        state.vel = state.vel.add(flow.scale(strength / len));
        sim.note(.liquid_flow, state);
    }
}

fn cellFlow(sim: *Simulator, pos: BlockPos, l: Liquid) Error!Vec3 {
    const current = l.decay();
    var flow: Vec3 = .zero;
    for (faces) |f| {
        const n = pos.offset(f.dx, 0, f.dz);
        const dir: Vec3 = .init(@floatFromInt(f.dx), 0, @floatFromInt(f.dz));
        if (try liquidAt(sim, n)) |nl| {
            if (nl.kind == l.kind) {
                if (!(try faceClosed(sim, pos, f.face)) and !(try faceClosed(sim, n, opposite(f.face)))) {
                    flow = flow.add(dir.scale(@floatFromInt(nl.decay() - current)));
                }
                continue;
            }
        }
        if ((try faceClosed(sim, pos, f.face)) or (try faceClosed(sim, n, opposite(f.face)))) continue;
        if (try liquidAt(sim, n.offset(0, -1, 0))) |lower| {
            if (lower.kind == l.kind) flow = flow.add(dir.scale(@floatFromInt(lower.decay() - current + 8)));
        }
    }
    if (l.falling) {
        for (faces) |f| {
            const n = pos.offset(f.dx, 0, f.dz);
            if ((try sim.block(n)).flow_barrier or (try sim.block(n.offset(0, 1, 0))).flow_barrier) {
                const len = flow.len();
                if (len > 1e-4) flow = flow.scale(1 / len);
                flow.y -= 6;
                break;
            }
        }
    }
    const len = flow.len();
    return if (len > 1e-4) flow.scale(1 / len) else .zero;
}

// Go evaluates these typed constants as f32 operations.
pub const swim_air_probe: f32 = @as(f32, 1.62) - @as(f32, 1.1);
pub const swim_liquid_probe: f32 = @as(f32, 1.62) - @as(f32, 1.2);

fn updateSwimTravel(sim: *Simulator, state: *State) Error!void {
    if (!state.swimming or state.effective_jumping) return;
    const pi: f32 = std.math.pi;
    const target = -math.mcSin(state.rotation.pitch * pi / 180);
    const rate: f32 = if (target < -0.2) 0.085 else 0.06;
    if (target > 0 and !state.want_down_slow and !state.pressing_descend) {
        const above = try sim.block(try cellAt(state.pos.x, state.pos.y + swim_air_probe, state.pos.z));
        if (above.liquid == null and above.isAir()) {
            if ((try liquidAt(sim, try cellAt(state.pos.x, state.pos.y + swim_liquid_probe, state.pos.z))) == null) {
                state.vel.y = 0;
                return;
            }
        }
    }
    state.vel.y += (target - state.vel.y) * rate;
}

fn waterSpeed(base: f32, ground_speed: f32, depth_strider: f32, swim_multiplier: f32, on_ground: bool) struct { speed: f32, depth_strider: f32 } {
    if (swim_multiplier > 1) return .{ .speed = base * swim_multiplier * (depth_strider / 3 * 0.3 + 0.7), .depth_strider = depth_strider };
    if (depth_strider <= 0) return .{ .speed = base, .depth_strider = depth_strider };
    const ds = if (on_ground) depth_strider else depth_strider * 0.5;
    return .{ .speed = base + (ground_speed - base) * ds / 3, .depth_strider = ds };
}

fn gravity(swimming: bool, water: bool) f32 {
    if (!water) return 0.02;
    return if (swimming) 0 else 0.005;
}

pub fn travel(sim: *Simulator, state: *State, kind: LiquidKind, touching_liquid: bool) Error!void {
    const initial_y = state.pos.y;
    const water = kind == .water;
    const jumping = state.effective_jumping;
    if (water) {
        if (state.want_down or state.want_down_slow or state.pressing_descend) state.vel.y -= 0.04;
        try updateSwimTravel(sim, state);
    }
    if (jumping) {
        if ((state.swim_amount > 0 and state.swim_amount < 1) or (water and state.swimming and !touching_liquid)) {
            state.vel.y = 0;
        } else {
            state.vel.y += 0.04;
        }
    }

    var speed = state.lava_speed;
    var depth_strider: f32 = 0;
    var swim_multiplier: f32 = 1;
    if (water) {
        if (state.swimming and state.swim_speed_multiplier != 0) swim_multiplier = state.swim_speed_multiplier;
        depth_strider = @floatFromInt(@min(state.equipment.depth_strider, 3));
        const w = waterSpeed(state.underwater_speed, state.movement_speed, depth_strider, swim_multiplier, state.on_ground);
        speed = w.speed;
        depth_strider = w.depth_strider;
    }
    Simulator.moveRelative(state, speed);
    sim.note(.move_relative, state);

    const stuck = Simulator.applyStuckSpeed(state);
    _ = try sim.moveWithCollisions(state);
    try sim.stopRiptideOnBlockCollision(state);
    if (stuck) {
        state.mov = state.vel;
        state.vel = .zero;
    }
    if (state.collide_y) state.vel.y = 0;
    if (state.collide_x) state.vel.x = 0;
    if (state.collide_z) state.vel.z = 0;
    if (!stuck) state.mov = state.vel;

    var v = state.vel;
    if (water) {
        var drag: f32 = if (state.sprinting or state.stopped_swimming_this_tick) 0.9 else 0.8;
        if (depth_strider > 0 and swim_multiplier <= 1) drag += (0.54600006 - drag) * (depth_strider / 3);
        v.x *= drag;
        v.y *= 0.8;
        v.z *= drag;
    } else {
        v = v.scale(0.5);
    }
    if (state.effects.levitation) |amp| {
        const target = Simulator.levitation_speed * @as(f32, @floatFromInt(@as(i64, amp) + 1));
        v.y += (target - v.y) * 0.2;
    } else if (state.has_gravity) {
        v.y -= gravity(state.swimming, water);
    }

    if (state.collide_x or state.collide_z) {
        const raised: Vec3 = .init(v.x, v.y + 0.6 + initial_y - state.pos.y, v.z);
        const box = state.boundingBox().translate(raised);
        const ctx = sim.collisionContext(state);
        if (!(try sim.anyCollision(box, &ctx)) and !(try containsAny(sim, box))) v.y = 0.3;
    }
    state.vel = v;
    sim.note(.liquid_travel, state);
    try contact.applyInsideBlockEffects(sim, state);
    state.fall_distance = 0;
}

pub const HeadLiquid = struct {
    position: Vec3 = .zero,
    water: bool = false,
    lava: bool = false,
};

pub fn headLiquid(sim: *Simulator, state: *const State) Error!HeadLiquid {
    const eye = state.eyePosition();
    var out: HeadLiquid = .{ .position = eye };
    const pos = try cellAt(eye.x, eye.y, eye.z);
    const l = (try liquidAt(sim, pos)) orelse return out;
    if (eye.y >= @as(f32, @floatFromInt(pos.y)) + l.height()) return out;
    out.water = l.kind == .water;
    out.lava = l.kind == .lava;
    return out;
}
