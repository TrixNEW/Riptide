const std = @import("std");
const math = @import("math.zig");
const world_mod = @import("world.zig");
const state_mod = @import("state.zig");
const liquid = @import("liquid.zig");
const Simulator = @import("Simulator.zig");

const Vec3 = math.Vec3;
const AABB = @import("aabb.zig").AABB;
const Block = world_mod.Block;
const BlockPos = world_mod.BlockPos;
const Semantics = world_mod.Semantics;
const State = state_mod.State;
const Error = Simulator.Error;

pub const scaffolding_speed: f32 = 0.15;
const min_restitution_speed: f32 = 0.08000011742115021;
const ground_probe_offset: f32 = -0.1;
const standing_probe_offset: f32 = -0.2;

pub fn cellAt(x: f32, y: f32, z: f32) Error!BlockPos {
    inline for (.{ x, y, z }) |v| {
        if (!std.math.isFinite(v) or !math.blockCoordInRange(v)) return error.QueryLimit;
    }
    return .init(math.floorI(x), math.floorI(y), math.floorI(z));
}

fn semanticsOf(b: *const Block) Error!Semantics {
    if (!b.semantics.isValid()) return error.InvalidWorld;
    return b.semantics;
}

pub fn groundFriction(sim: *Simulator, state: *const State) Error!Semantics {
    const min_y = state.boundingBox().min.y;
    const b = try sim.block(try cellAt(state.pos.x, min_y + ground_probe_offset, state.pos.z));
    if (b.isAir()) return .{};
    return semanticsOf(&b);
}

pub fn landingBlock(sim: *Simulator, box: AABB, boxes: []const AABB) Error!?Block {
    const plane_y = box.min.y + standing_probe_offset;
    const cx = (box.max.x - box.min.x) * 0.5 + box.min.x;
    const cz = (box.max.z - box.min.z) * 0.5 + box.min.z;
    var best: ?usize = null;
    var best_gap: f32 = std.math.floatMax(f32);
    var best_dist: f32 = 0;
    for (boxes, 0..) |c, i| {
        const cy = (c.max.y - c.min.y) * 0.5 + c.min.y;
        const gap = plane_y - cy;
        if (gap < 0) continue;
        const dx = (c.max.x - c.min.x) * 0.5 + c.min.x - cx;
        const dy = cy - plane_y;
        const dz = (c.max.z - c.min.z) * 0.5 + c.min.z - cz;
        const dist = (dz * dz + dy * dy) + dx * dx;
        const pos = sim.scratch.owners[i];
        if (best == null or gap < best_gap or (gap == best_gap and (dist < best_dist or
            (dist == best_dist and pos.gathersBefore(sim.scratch.owners[best.?])))))
        {
            best = i;
            best_gap = gap;
            best_dist = dist;
        }
    }
    const i = best orelse return null;
    return try sim.block(sim.scratch.owners[i]);
}

pub fn restitution(sim: *Simulator, state: *const State, impact_y: f32, landed: ?Block) f32 {
    const b = landed orelse return 0;
    if (state.sneaking or impact_y >= 0 or @abs(impact_y) < min_restitution_speed) return 0;
    const s = b.semantics;
    const bounciness: f32 = if (s.honey) return 0 else switch (s.bounce) {
        .slime => 1,
        .bed => 0.75,
        .none => 0,
    };
    const v = @max(bounciness * -impact_y, 0);
    if (v != 0) sim.mech.bounce = true;
    return v;
}

fn standingOnBlock(sim: *Simulator, state: *const State) Error!?Block {
    const box = state.boundingBox();
    const plane_y = box.min.y + standing_probe_offset;
    const center: Vec3 = .init((box.max.x - box.min.x) * 0.5 + box.min.x, plane_y, (box.max.z - box.min.z) * 0.5 + box.min.z);
    const lo = try cellAt(box.min.x, plane_y, box.min.z);
    const hi = try cellAt(box.max.x, plane_y, box.max.z);
    const ctx = sim.collisionContext(state);
    var best_pos: ?BlockPos = null;
    var best_top: f32 = -std.math.floatMax(f32);
    var best_dist: f32 = 0;
    var x = lo.x;
    while (x <= hi.x) : (x += 1) {
        var z = lo.z;
        while (z <= hi.z) : (z += 1) {
            for ([_]i32{ lo.y, lo.y -% 1 }) |y| {
                const pos: BlockPos = .init(x, y, z);
                const b = try sim.block(pos);
                const local = shapeBounds(sim.cellShape(pos, &b, &ctx)) orelse continue;
                const s = local.translate(pos.vec());
                if (s.max.x <= box.min.x or s.min.x >= box.max.x or s.max.z <= box.min.z or s.min.z >= box.max.z or
                    s.max.y <= plane_y or s.min.y >= plane_y or best_top > s.max.y) continue;
                const dx = center.x - ((s.max.x - s.min.x) * 0.5 + s.min.x);
                const dy = center.y - ((s.max.y - s.min.y) * 0.5 + s.min.y);
                const dz = center.z - ((s.max.z - s.min.z) * 0.5 + s.min.z);
                const dist = (dz * dz + dy * dy) + dx * dx;
                if (best_top < s.max.y or dist < best_dist) {
                    best_top = s.max.y;
                    best_dist = dist;
                    best_pos = pos;
                }
            }
        }
    }
    return if (best_pos) |p| try sim.block(p) else null;
}

fn shapeBounds(boxes: []const AABB) ?AABB {
    var out: ?AABB = null;
    for (boxes) |b| {
        if (b.isDegenerate()) continue;
        if (out) |*o| {
            o.min = .init(@min(o.min.x, b.min.x), @min(o.min.y, b.min.y), @min(o.min.z, b.min.z));
            o.max = .init(@max(o.max.x, b.max.x), @max(o.max.y, b.max.y), @max(o.max.z, b.max.z));
        } else out = b;
    }
    return out;
}

pub fn applyStandOnDamping(sim: *Simulator, state: *State) Error!void {
    if (!state.on_ground or state.sneaking or state.vel.y >= 0.1) return;
    const b = (try standingOnBlock(sim, state)) orelse return;
    if (b.semantics.bounce != .slime and !b.semantics.honey) return;
    if (b.semantics.honey) sim.mech.honey = true;
    const factor = @abs(state.vel.y) * 0.2 + 0.4;
    state.vel.x *= factor;
    state.vel.z *= factor;
}

pub fn jumpFactorHoney(sim: *Simulator, state: *const State) Error!bool {
    const min_y = state.boundingBox().min.y;
    const feet_y = @floor(min_y);
    const pos = try cellAt(state.pos.x, feet_y, state.pos.z);
    const feet = try sim.block(pos);
    if (feet.semantics.honey) return true;
    if (min_y > feet_y and !feet.semantics.carpet) return false;
    return (try sim.block(pos.offset(0, -1, 0))).semantics.honey;
}

pub fn updateSupportingBlock(sim: *Simulator, state: *State, vel: Vec3) Error!void {
    if (!state.on_ground) {
        state.supporting_block = null;
        return;
    }
    var probe = state.boundingBox().extendDown(1e-3);
    state.supporting_block = try findSupportingBlock(sim, state, probe);
    if (state.supporting_block == null) {
        probe = probe.translate(.init(-vel.x, 0, -vel.z));
        state.supporting_block = try findSupportingBlock(sim, state, probe);
    }
}

fn findSupportingBlock(sim: *Simulator, state: *const State, bb: AABB) Error!?BlockPos {
    // Cells past the maximum face cannot intersect, unlike BedSim's ceil(max) range.
    const r = try sim.cellRange(bb, 0, false);
    const feet = try cellAt(state.pos.x, state.pos.y, state.pos.z);
    const center = feet.vec().add(.init(0.5, 0.5, 0.5));
    const ctx = sim.collisionContext(state);
    var best: ?BlockPos = null;
    var min_dist: f32 = std.math.floatMax(f32);
    var y = r.y0;
    while (y <= r.y1) : (y += 1) {
        var x = r.x0;
        while (x <= r.x1) : (x += 1) {
            var z = r.z0;
            while (z <= r.z1) : (z += 1) {
                const pos: BlockPos = .init(x, y, z);
                const b = try sim.block(pos);
                if (b.shape.len == 0 and !b.dynamic_shape) continue;
                const origin = pos.vec();
                for (sim.cellShape(pos, &b, &ctx)) |local| {
                    if (local.isDegenerate()) continue;
                    if (!bb.intersects(local.translate(origin))) continue;
                    const dist = origin.sub(center).lenSqr();
                    if (dist < min_dist) {
                        min_dist = dist;
                        best = pos;
                    }
                    break;
                }
            }
        }
    }
    return best;
}

pub const Climber = struct {
    in_scaffolding: bool = false,
    over_scaffolding: bool = false,
    in_ascendable: bool = false,
    over_descendable: bool = false,
    climbable: bool = false,
    hold_on_sneak: bool = false,
};

pub fn climberFlags(sim: *Simulator, state: *const State) Error!Climber {
    const bb = state.boundingBox();
    const boots = state.equipment.leather_boots;
    var c: Climber = .{};
    const feet = try cellAt(bb.min.x, bb.min.y, bb.min.z);
    const over = try cellAt(bb.min.x, bb.min.y + (-1), bb.min.z);
    const far = try cellAt(bb.max.x, bb.min.y, bb.max.z);
    try climberLayer(sim, feet, far, feet.y, boots, &c.in_scaffolding, &c.in_ascendable);
    try climberLayer(sim, feet, far, over.y, boots, &c.over_scaffolding, &c.over_descendable);
    const at = try climbableAtFeet(sim, state);
    c.climbable = at.climbable;
    c.hold_on_sneak = at.hold_on_sneak;
    if (c.in_scaffolding or c.over_scaffolding) sim.mech.scaffolding = true;
    return c;
}

fn climberLayer(sim: *Simulator, lo: BlockPos, hi: BlockPos, y: i32, boots: bool, scaffolding: *bool, ascendable: *bool) Error!void {
    var x = lo.x;
    while (x <= hi.x) : (x += 1) {
        var z = lo.z;
        while (z <= hi.z) : (z += 1) {
            const pos: BlockPos = .init(x, y, z);
            switch ((try sim.block(pos)).semantics.traversal) {
                .scaffolding => {
                    scaffolding.* = true;
                    if (!ascendable.*) {
                        const below = try sim.block(pos.offset(0, -1, 0));
                        const water = below.kind == .liquid and below.liquid != null and below.liquid.?.kind == .water;
                        ascendable.* = !below.isAir() and !water;
                    }
                },
                .powder_snow => {
                    sim.mech.powder_snow = true;
                    ascendable.* = ascendable.* or boots;
                },
                .none => {},
            }
        }
    }
}

const AtFeet = struct { climbable: bool, hold_on_sneak: bool };

fn climbableAtFeet(sim: *Simulator, state: *const State) Error!AtFeet {
    const s = (try sim.block(try cellAt(state.pos.x, state.pos.y, state.pos.z))).semantics;
    if (s.climbable) return .{ .climbable = true, .hold_on_sneak = true };
    return .{ .climbable = state.equipment.leather_boots and s.traversal == .powder_snow, .hold_on_sneak = false };
}

pub fn applyClimbJump(state: *State, c: Climber) bool {
    if (!state.effective_jumping and !state.pressing_ascend and !state.jumping) return false;
    if ((c.in_scaffolding or c.in_ascendable) and !state.descend_through_block) {
        state.vel.y = scaffolding_speed;
        state.jump_delay = state_mod.jump_delay_ticks;
    } else if (c.climbable) {
        state.vel.y = Simulator.climb_speed;
    } else return false;
    return true;
}

pub fn applyLadderTravel(state: *State, c: Climber) void {
    if (!c.climbable) return;
    if (state.vel.y < -Simulator.climb_speed) state.vel.y = -Simulator.climb_speed;
    if (c.hold_on_sneak and state.sneaking and state.vel.y < 0) state.vel.y = 0;
}

pub fn applyAutoClimb(sim: *Simulator, state: *State) Error!bool {
    if (!state.collide_x and !state.collide_z) return false;
    if (!(try climbableAtFeet(sim, state)).climbable) return false;
    sim.mech.climb = true;
    state.vel.y = Simulator.climb_speed;
    return true;
}

const CellBox = struct { lo: BlockPos, hi: BlockPos };

fn insideCells(bb: AABB) Error!CellBox {
    return .{
        .lo = try cellAt(bb.min.x + 0.001, bb.min.y + 0.001, bb.min.z + 0.001),
        .hi = try cellAt(bb.max.x - 0.001, bb.max.y - 0.001, bb.max.z - 0.001),
    };
}

fn queueStuckSpeed(state: *State, m: Vec3) void {
    const q = state.stuck_speed;
    if (q.lenSqr() <= 1e-7) {
        state.stuck_speed = m;
        return;
    }
    state.stuck_speed = .init(@min(q.x, m.x), @min(q.y, m.y), @min(q.z, m.z));
}

pub fn applyInsideBlockEffects(sim: *Simulator, state: *State) Error!void {
    const r = try insideCells(state.boundingBox());
    try applyBubbleColumns(sim, state, r);
    if (!state.swim_water_contact) try applyHoneyWallSlide(sim, state, r);
    var berry = false;
    var powder = false;
    var web = false;
    var x = r.lo.x;
    while (x <= r.hi.x) : (x += 1) {
        var y = r.lo.y;
        while (y <= r.hi.y) : (y += 1) {
            var z = r.lo.z;
            while (z <= r.hi.z) : (z += 1) {
                const b = try sim.block(.init(x, y, z));
                if (b.isAir()) continue;
                berry = berry or b.semantics.inside == .sweet_berry_bush;
                powder = powder or b.semantics.inside == .powder_snow;
                web = web or b.semantics.cobweb;
            }
        }
    }
    if (powder) {
        sim.mech.powder_snow = true;
        queueStuckSpeed(state, .init(0.9, 1.5, 0.9));
    }
    if (web) {
        sim.mech.cobweb = true;
        const weaving = !berry and !powder and state.effects.weaving;
        queueStuckSpeed(state, if (weaving) .init(0.5, 0.25, 0.5) else .init(0.25, 0.05, 0.25));
    }
    if (berry) {
        sim.mech.sweet_berry_bush = true;
        queueStuckSpeed(state, .init(0.8, 0.75, 0.8));
    }
    if (berry or powder or web) state.fall_distance = 0;
}

fn applyHoneyWallSlide(sim: *Simulator, state: *State, r: CellBox) Error!void {
    var x = r.lo.x;
    while (x <= r.hi.x) : (x += 1) {
        var y = r.lo.y;
        while (y <= r.hi.y) : (y += 1) {
            var z = r.lo.z;
            while (z <= r.hi.z) : (z += 1) {
                const pos: BlockPos = .init(x, y, z);
                if (!(try sim.block(pos)).semantics.honey) continue;
                sim.mech.honey = true;
                state.vel.x *= 0.4;
                state.vel.y = @max(-0.12, state.vel.y);
                state.vel.z *= 0.4;
                if (honeySideContact(state, pos)) state.fall_distance = 0;
            }
        }
    }
}

fn honeySideContact(state: *const State, pos: BlockPos) bool {
    if (state.vel.y >= 0 or state.pos.y > @as(f32, @floatFromInt(pos.y)) + 0.9375) return false;
    const radius = state.size.width * state.size.scale * 0.5 + 0.43125;
    const cx = @as(f32, @floatFromInt(pos.x)) + 0.5;
    const cz = @as(f32, @floatFromInt(pos.z)) + 0.5;
    return @abs(cx - state.pos.x) > radius or @abs(cz - state.pos.z) > radius;
}

fn applyBubbleColumns(sim: *Simulator, state: *State, r: CellBox) Error!void {
    var found = false;
    var x = r.lo.x;
    while (x <= r.hi.x) : (x += 1) {
        var y = r.lo.y;
        while (y <= r.hi.y) : (y += 1) {
            var z = r.lo.z;
            while (z <= r.hi.z) : (z += 1) {
                const pos: BlockPos = .init(x, y, z);
                const b = try sim.block(pos);
                if (b.bubble == .none) continue;
                found = true;
                const surface = b.bubble_surface orelse blk: {
                    const above = try sim.block(pos.offset(0, 1, 0));
                    break :blk above.liquid == null and above.isAir();
                };
                if (b.bubble == .down) {
                    const cap: f32 = if (surface) -0.9 else -0.3;
                    state.vel.y = @max(cap, state.vel.y - 0.03);
                } else {
                    const change: f32 = if (surface) 0.1 else 0.06;
                    const cap: f32 = if (surface) 1.8 else 0.7;
                    state.vel.y = @min(cap, state.vel.y + change);
                }
            }
        }
    }
    if (found) {
        sim.mech.bubble_column = true;
        state.fall_distance = 0;
    }
}

pub fn attemptRiptide(sim: *Simulator, state: *State, touching_water: bool) Error!void {
    if (state.in_vehicle or state.riptide_ticks > 0 or !state.riptide_ready) return;
    if (!touching_water and !state.riptide_in_rain) return;
    const level = state.equipment.riptide;
    if (level == 0 or !state.starting_spin_attack) return;
    var head_in_water = false;
    if (state.on_ground and state.has_gravity and touching_water) {
        head_in_water = (try liquid.headLiquid(sim, state)).water;
    }
    state.vel = state.vel.add(riptideImpulse(state, level, touching_water, head_in_water));
    state.riptide_ticks = state_mod.riptide_ticks;
    state.riptide_collision = false;
    state.starting_spin_attack = false;
    sim.mech.riptide = true;
    sim.note(.riptide_launch, state);
}

fn riptideImpulse(state: *const State, level: u8, was_in_water: bool, head_in_water: bool) Vec3 {
    const pi: f32 = std.math.pi;
    const force = 0.75 * @as(f32, @floatFromInt(@as(u16, level) + 1));
    const pitch = state.rotation.pitch * pi / 180;
    const yaw = state.rotation.yaw * pi / 180;
    var d: Vec3 = .init(-math.mcSin(yaw) * math.mcCos(pitch), -math.mcSin(pitch), math.mcCos(yaw) * math.mcCos(pitch));
    const len = d.len();
    if (len > 0) d = d.scale(force / len);
    if (state.on_ground and state.has_gravity) {
        if (was_in_water and !head_in_water) {
            d.y = d.y / 0.8 * Simulator.vertical_drag;
        } else {
            d.y += state.gravity;
        }
    }
    return d;
}
