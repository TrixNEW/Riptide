//! Bedrock player movement simulator.
//!
//! A `Simulator` holds configuration, the world view, and scratch memory.
//! It never allocates. Use one per thread; any number of `State`s can be
//! advanced through it.

const std = @import("std");
const math = @import("math.zig");
const aabb_mod = @import("aabb.zig");
const world_mod = @import("world.zig");
const state_mod = @import("state.zig");
const trace_mod = @import("trace.zig");
const contact = @import("contact.zig");
const liquid = @import("liquid.zig");

const Vec3 = math.Vec3;
const Vec2 = math.Vec2;
const AABB = aabb_mod.AABB;
const World = world_mod.World;
const Block = world_mod.Block;
const BlockPos = world_mod.BlockPos;
const CollisionContext = world_mod.CollisionContext;
const ShapeBuffer = world_mod.ShapeBuffer;
const State = state_mod.State;
const Input = state_mod.Input;
const Config = state_mod.Config;
const Result = state_mod.Result;
const Outcome = state_mod.Outcome;
const Mechanics = state_mod.Mechanics;
const Trace = trace_mod.Trace;
const Stage = trace_mod.Stage;

const Simulator = @This();

world: World,
config: Config,
/// Optional stage trace. Null in production.
trace: ?*Trace = null,
scratch: Scratch = .{},
cache: BlockCache = .{},
mech: Mechanics = .{},

pub const Error = error{ Unloaded, QueryLimit, InvalidWorld };

pub const max_boxes = 2048;
pub const max_liquid_cells = 512;

pub const Scratch = struct {
    boxes: [max_boxes]AABB = undefined,
    owners: [max_boxes]BlockPos = undefined,
    len: usize = 0,
    dynamic: ShapeBuffer = .{},
    water: [max_liquid_cells]BlockPos = undefined,
    water_len: usize = 0,
    lava: [max_liquid_cells]BlockPos = undefined,
    lava_len: usize = 0,
};

/// Direct-mapped cache of world lookups. A tick probes most cells several
/// times; entries are valid only within one simulator call because the world
/// may change between calls.
pub const BlockCache = struct {
    const bits = 7;
    const size = 1 << bits;

    keys: [size]BlockPos = undefined,
    stamps: [size]u32 = @splat(0),
    blocks: [size]Block = undefined,
    generation: u32 = 1,

    fn slot(pos: BlockPos) usize {
        const h = @as(u32, @bitCast(pos.x)) *% 0x9E3779B1 ^ @as(u32, @bitCast(pos.y)) *% 0x85EBCA77 ^ @as(u32, @bitCast(pos.z)) *% 0xC2B2AE3D;
        return h >> (32 - bits);
    }

    pub fn invalidate(c: *BlockCache) void {
        c.generation +%= 1;
        if (c.generation == 0) {
            c.stamps = @splat(0);
            c.generation = 1;
        }
    }
};

pub const step_height: f32 = 0.5625;
pub const air_drag: f32 = 0.91;
pub const default_friction: f32 = 0.6;
pub const vertical_drag: f32 = 0.98;
pub const slow_falling_gravity: f32 = 0.01;
pub const levitation_speed: f32 = 0.05;
pub const climb_speed: f32 = 0.2;
pub const max_sneak_impulse: f32 = 0.3;
pub const max_consuming_impulse: f32 = @as(f32, 0.35) * @as(f32, 0.35);
pub const deg_to_rad: f32 = @as(f32, std.math.pi) / 180.0;
const swim_trusted: u16 = std.math.maxInt(u16);

pub fn init(world: World, config: Config) Simulator {
    return .{ .world = world, .config = config };
}

pub inline fn note(sim: *Simulator, stage: Stage, state: *const State) void {
    if (sim.trace) |t| t.record(stage, state.pos, state.vel, state.on_ground);
}

// ---------------------------------------------------------------- lifecycle

/// Advances `state` by one client tick. On any non-`normal` outcome the
/// state is left consistent and safe to keep using.
pub fn tick(sim: *Simulator, state: *State, input: *const Input) Result {
    sim.mech = .{};
    sim.cache.invalidate();
    defer if (sim.trace) |t| {
        t.tick += 1;
    };
    if (!state.isValid()) return .{ .outcome = .invalid_input };
    if (!input.isValid()) return sim.result(state, .invalid_input, .{});
    if (sim.config.policy.swim_grace == .trust_client) state.swim_grace_ticks = swim_trusted;

    const before = state.*;
    sim.prepareCollisionBox(state);
    const pose: PoseSnapshot = .take(state);
    const prepared = sim.applyInput(state, input);
    sim.note(.input, state);

    var outcome: Outcome = prepared.failure;
    if (prepared.failure == .normal or state.teleport != null or state.in_vehicle) {
        outcome = sim.simulateCore(state);
    } else {
        state.vel = .zero;
        sim.clearSwimEvidence(state);
        state.stuck_speed = .zero;
    }
    if (sim.config.sprint_timing == .legacy) {
        applySprint(state, input, true, true);
        state.air_speed = airSpeed(state);
    }

    if (isWorldFailure(outcome)) {
        pose.restore(state);
    } else {
        state.air_speed = airSpeed(state);
        tickTimers(state);
    }
    if (!(state.pos.isFinite() and state.vel.isFinite() and state.mov.isFinite() and std.math.isFinite(state.fall_distance))) {
        // Only reachable with extreme but finite values, such as a motion
        // that overflows the position.
        state.* = before;
        state.vel = .zero;
        state.pending_motion = null;
        outcome = .invalid_input;
    }
    sim.note(.final, state);
    return sim.result(state, outcome, prepared.move);
}

fn isWorldFailure(o: Outcome) bool {
    return o == .unloaded or o == .query_limit or o == .invalid_world;
}

fn failureOutcome(e: Error) Outcome {
    return switch (e) {
        error.Unloaded => .unloaded,
        error.QueryLimit => .query_limit,
        error.InvalidWorld => .invalid_world,
    };
}

fn result(sim: *Simulator, state: *const State, outcome: Outcome, move: Vec2) Result {
    return .{
        .outcome = outcome,
        .pos = state.pos,
        .vel = state.vel,
        .mov = state.mov,
        .on_ground = state.on_ground,
        .collide_x = state.collide_x,
        .collide_y = state.collide_y,
        .collide_z = state.collide_z,
        .position_delta = state.pos.sub(state.reported.pos),
        .velocity_delta = state.vel.sub(state.reported.vel),
        .input_move = move,
        .sprint_movement_blocked = outcome == .normal and state.sprint_movement_blocked,
        .mechanics = if (outcome == .normal) sim.mech else .{},
    };
}

/// Pose fields restored when the world could not be observed.
const PoseSnapshot = struct {
    shape: state_mod.CollisionShape,
    size: state_mod.Size,
    sneaking: bool,
    crawling: bool,
    swimming: bool,
    swim_amount: f32,
    gliding: bool,
    riptide_ticks: u8,
    riptide_collision: bool,

    fn take(s: *const State) PoseSnapshot {
        return .{
            .shape = s.shape,
            .size = s.size,
            .sneaking = s.sneaking,
            .crawling = s.crawling,
            .swimming = s.swimming,
            .swim_amount = s.swim_amount,
            .gliding = s.gliding,
            .riptide_ticks = s.riptide_ticks,
            .riptide_collision = s.riptide_collision,
        };
    }

    fn restore(p: PoseSnapshot, s: *State) void {
        s.shape = p.shape;
        s.size = p.size;
        s.sneaking = p.sneaking;
        s.crawling = p.crawling;
        s.swimming = p.swimming;
        s.swim_amount = p.swim_amount;
        s.gliding = p.gliding;
        s.riptide_ticks = p.riptide_ticks;
        s.riptide_collision = p.riptide_collision;
    }
};

fn simulateCore(sim: *Simulator, state: *State) Outcome {
    state.sprint_movement_blocked = false;
    var clear_riptide_ready = true;
    defer if (clear_riptide_ready) {
        state.riptide_ready = false;
    };

    if (sim.attemptTeleport(state)) {
        // A teleport does not observe the destination, so retained water
        // contact from the origin is void.
        sim.clearSwimEvidence(state);
        state.stuck_speed = .zero;
        return .teleport;
    }
    if (state.in_vehicle) {
        sim.resetToReported(state);
        state.on_ground = false;
        state.collide_x = false;
        state.collide_y = false;
        state.collide_z = false;
        return .mounted;
    }
    if (!simulationReliable(state)) {
        sim.resetToReported(state);
        return .client_authoritative;
    }
    sim.prepareCollisionBox(state);
    if (state.immobile or !state.ready) {
        state.vel = .zero;
        // Frozen ticks observe nothing, so retained contact must not resume.
        sim.clearSwimEvidence(state);
        state.stuck_speed = .zero;
        return .immobile;
    }

    const before = state.*;
    sim.simulateMovement(state) catch |e| {
        state.* = before;
        clear_riptide_ready = false;
        state.vel = .zero;
        // An unsimulatable motion would otherwise fail every later tick.
        if (e == error.QueryLimit) state.pending_motion = null;
        sim.clearSwimEvidence(state);
        state.stuck_speed = .zero;
        return failureOutcome(e);
    };
    // The last Riptide tick becomes upright when the timer expires. Validate
    // that resize before committing movement.
    if (state.riptide_ticks == 1 and !state.gliding and !state.swimPose()) {
        sim.restoreUprightPose(state) catch |e| {
            state.* = before;
            clear_riptide_ready = false;
            state.vel = .zero;
            sim.clearSwimEvidence(state);
            state.stuck_speed = .zero;
            return failureOutcome(e);
        };
    }
    return .normal;
}

fn simulationReliable(state: *const State) bool {
    if (state.game_mode != .survival and state.game_mode != .adventure) return false;
    return !(state.flying or state.just_disabled_flight or state.no_clip or !state.alive);
}

fn resetToReported(sim: *Simulator, state: *State) void {
    // A frame we did not simulate proves nothing about water contact.
    sim.clearSwimEvidence(state);
    state.stuck_speed = .zero;
    state.pos = state.reported.pos;
    state.shape.valid = false;
    state.vel = state.reported.vel;
    state.mov = state.reported.pos.sub(state.reported.last_pos);
    state.supporting_block = null;
    if (state.flying or state.no_clip) state.on_ground = false;
}

fn tickTimers(state: *State) void {
    if (state.glide_boost_ticks > 0) state.glide_boost_ticks -= 1;
    if (state.dolphin_boost_ticks > 0) {
        state.dolphin_boost_ticks -= 1;
        if (state.dolphin_boost_ticks == 0) state.swim_speed_multiplier = 1;
    }
    state.pending_motion = null;
    if (state.jump_delay > 0) state.jump_delay -= 1;
    if (state.riptide_ticks > 0) {
        state.riptide_ticks -= 1;
        if (state.riptide_ticks == 0) state.riptide_collision = false;
    }
    state.just_disabled_flight = false;
    state.stopped_swimming_this_tick = false;
}

fn attemptTeleport(sim: *Simulator, state: *State) bool {
    const tp = &(state.teleport orelse return false);
    if (!tp.smoothed) {
        state.pos = tp.target;
        state.vel = .zero;
    } else {
        const factor = 1.0 / @as(f32, @floatFromInt(tp.remaining));
        state.pos = state.pos.add(tp.target.sub(state.pos).scale(factor));
    }
    state.rememberBox(state.boxAt(state.pos));
    state.supporting_block = null;
    state.jump_delay = 0;
    if (tp.remaining <= 1) {
        state.teleport = null;
    } else {
        tp.remaining -= 1;
    }
    sim.note(.teleport, state);
    return true;
}

// -------------------------------------------------------------------- input

const Prepared = struct {
    /// `normal` when the pose world was observable.
    failure: Outcome,
    move: Vec2,
};

/// Pose queries during input processing. Failures are remembered rather
/// than propagated, matching the client's input handling.
const PoseQuery = struct {
    sim: *Simulator,
    state: *State,
    failure: ?Error = null,

    fn fits(q: *PoseQuery, height: f32) bool {
        return q.sim.canFitHeight(q.state, height) catch |e| {
            q.failure = q.failure orelse e;
            return false;
        };
    }

    fn restoreUpright(q: *PoseQuery) void {
        q.sim.restoreUprightPose(q.state) catch |e| {
            q.failure = q.failure orelse e;
        };
    }
};

fn applyInput(sim: *Simulator, state: *State, input: *const Input) Prepared {
    const f = input.flags;
    const was_flight_pose = state.gliding or state.riptide_ticks > 0;
    var q: PoseQuery = .{ .sim = sim, .state = state };
    const pose_known = blk: {
        sim.areaKnown(state.boundingBox()) catch |e| {
            q.failure = e;
            break :blk false;
        };
        break :blk true;
    };

    state.reported.horizontal_collision = f.horizontal_collision;
    state.reported.vertical_collision = f.vertical_collision;
    state.reported.last_pos = state.reported.pos;
    state.reported.pos = input.reported_pos;
    state.reported.vel = input.reported_vel;

    if (f.start_flying) {
        state.reported.toggled_fly = true;
        if (state.trust_fly_status) state.flying = true;
    } else if (f.stop_flying) {
        if (state.flying) state.just_disabled_flight = true;
        state.flying = false;
        state.reported.toggled_fly = false;
    }

    state.last_rotation = state.rotation;
    state.rotation = input.rotation;
    state.pressing_ascend = f.ascend_block or f.jumping;
    state.pressing_descend = f.descend_block or f.sneaking;

    applySprint(state, input, false, sim.config.sprint_timing == .modern);
    state.air_speed = airSpeed(state);

    const sz = &state.size;
    const want_sneak = (f.sneak_down or f.start_sneaking) and !f.stop_sneaking;
    if (f.start_sneaking) {
        state.sneaking = true;
        if (!state.crawling) sz.height = sz.sneaking_height;
    } else if (f.stop_sneaking) {
        if (state.crawling) {
            state.sneaking = false;
        } else if (pose_known and q.fits(sz.standing_height)) {
            state.sneaking = false;
            sz.height = sz.standing_height;
        } else {
            state.sneaking = true;
            sz.height = sz.sneaking_height;
        }
    } else if (state.crawling) {
        state.sneaking = false;
    } else if (f.sneak_down) {
        state.sneaking = true;
        sz.height = sz.sneaking_height;
    } else if (state.sneaking and (!pose_known or !q.fits(sz.standing_height))) {
        sz.height = sz.sneaking_height;
    } else {
        state.sneaking = false;
        sz.height = sz.standing_height;
    }
    if (f.start_crawling) {
        if (pose_known and !q.fits(sz.standing_height)) {
            state.crawling = true;
            state.sneaking = false;
            sz.height = sz.crawling_height;
        }
    } else if (f.stop_crawling) {
        const target = if (want_sneak) sz.sneaking_height else sz.standing_height;
        if (pose_known and q.fits(target)) {
            state.crawling = false;
            state.sneaking = want_sneak;
            sz.height = target;
        } else {
            state.crawling = true;
            sz.height = sz.crawling_height;
        }
    }

    const was_swimming = state.swimming;
    state.stopped_swimming_this_tick = was_swimming and f.stop_swimming;
    if (f.stop_swimming) {
        state.swimming = false;
        if (pose_known) q.restoreUpright() else q.failure = q.failure orelse error.Unloaded;
    } else if (f.start_swimming) {
        state.swimming = true;
        if (state.swimPose() or (pose_known and q.fits(sz.standing_height))) setSwimmingPose(state);
    }
    state.swim_amount = math.clamp(if (was_swimming) state.swim_amount + 0.1 else state.swim_amount - 0.1, 0, 1);
    state.want_down = f.want_down;
    state.want_down_slow = f.want_down_slow;

    // Raw controls get the client's slowdown. Processed vectors are bounded
    // by the slowdown they should already carry.
    var item_modifier: f32 = 1;
    if (input.item_use_modifier) |m| {
        item_modifier = m;
    } else if (f.using_consumable or (f.using_item and !f.using_spear)) {
        item_modifier = max_consuming_impulse;
    }
    const pose_modifier = sneakModifier(state, input);
    var move: Vec2 = undefined;
    if (input.move_is_raw) {
        // Normalise onto the unit circle, then round the pose and item-use
        // products separately.
        var raw = input.move;
        const len_sqr = raw.y * raw.y + raw.x * raw.x;
        if (len_sqr > 1) {
            const len = @sqrt(len_sqr);
            raw = .{ .x = raw.x / len, .y = raw.y / len };
        }
        move = .{ .x = raw.x * pose_modifier * item_modifier, .y = raw.y * pose_modifier * item_modifier };
    } else {
        const bound = pose_modifier * item_modifier;
        move = .{ .x = math.clamp(input.move.x, -bound, bound), .y = math.clamp(input.move.y, -bound, bound) };
    }
    if (f.inventory_action) move = .{};

    // Ground jumps are edge-triggered; liquid and ladder ascent may be held.
    state.jumping = f.start_jumping;
    state.pressing_jump = f.jumping;
    state.effective_jumping = f.jumping or f.auto_jumping_in_water or f.ascend_block;
    state.jump_height = if (state.jump_strength > 0) state.jump_strength else state_mod.default_jump_strength;
    if (state.effects.jump_boost) |amp| {
        state.jump_height += @as(f32, @floatFromInt(@as(i64, amp) + 1)) * 0.1;
    }
    if (!state.pressing_jump) state.jump_delay = 0;

    if (f.stop_gliding) {
        state.gliding = false;
    } else if (f.start_gliding) {
        state.gliding = true;
    }
    // A rocket used without gliding is consumed without thrust.
    if (state.firework_pending and state.gliding and !f.stop_gliding) {
        state.glide_boost_ticks = state_mod.glide_boost_ticks;
    }
    state.firework_pending = false;

    // Keep a validated launch edge pending when an unloaded tick could not
    // consume it.
    state.starting_spin_attack = f.start_spin_attack or (state.riptide_ready and state.starting_spin_attack);
    if (f.stop_spin_attack and state.riptide_ticks > 0 and state.riptide_collision) {
        state.riptide_ticks = 0;
        state.riptide_collision = false;
        state.vel = state.vel.scale(-0.2);
    }

    if (was_flight_pose and !state.gliding and state.riptide_ticks == 0 and !state.swimPose()) {
        if (pose_known) q.restoreUpright() else q.failure = q.failure orelse error.Unloaded;
    }
    state.impulse = .{ .x = move.x * 0.98, .y = move.y * 0.98 };
    return .{ .failure = if (q.failure) |e| failureOutcome(e) else .normal, .move = move };
}

/// Pose slowdown for horizontal input. It applies to held sneak or descend
/// and to the sneaking and crawling poses, but never while swimming, flying,
/// or in water last tick.
fn sneakModifier(state: *State, input: *const Input) f32 {
    const f = input.flags;
    const slowed = state.sneaking or state.crawling or f.sneak_down or f.descend_block;
    if (!slowed or state.swimming or state.flying or state.swim_water_contact) {
        state.ticks_since_can_slowdown = 0;
        return 1;
    }
    state.ticks_since_can_slowdown +|= 1;
    var multiplier = max_sneak_impulse;
    if ((state.sneaking or state.crawling) and state.ticks_since_can_slowdown > 2) {
        const level: f32 = @floatFromInt(state.equipment.swift_sneak);
        multiplier = level * 0.15 + max_sneak_impulse;
    }
    return math.clamp(multiplier, 0, 1);
}

/// Sprint edge handling. Before movement it also adopts server sprint
/// metadata. Legacy clients change the movement attribute only after
/// movement (`late`).
fn applySprint(state: *State, input: *const Input, late: bool, adjust_speed: bool) void {
    const f = input.flags;
    var adjust = false;
    if (f.start_sprinting and f.stop_sprinting) {
        state.sprinting = false;
        adjust = true;
    } else if (!late and !f.start_sprinting and !f.stop_sprinting and !state.server_sprint_applied and state.server_sprint != state.sprinting) {
        state.sprinting = state.server_sprint;
    } else if (f.start_sprinting) {
        state.sprinting = true;
        adjust = true;
    } else if (f.stop_sprinting) {
        state.sprinting = false;
        adjust = !state.server_updated_speed;
    }
    if (!late) state.server_sprint_applied = true;
    if (adjust and adjust_speed) {
        state.server_updated_speed = false;
        state.movement_speed = state.default_movement_speed;
        if (state.sprinting) state.movement_speed *= 1.3;
    }
}

/// Vanilla selects air acceleration from the sprint flag alone; movement
/// effects do not reach it.
fn airSpeed(state: *const State) f32 {
    return if (state.sprinting) state_mod.sprint_air_speed else state_mod.walk_air_speed;
}

fn setSwimmingPose(state: *State) void {
    state.sneaking = false;
    state.crawling = false;
    state.size.height = state.size.standing_height;
}

// ------------------------------------------------------------- swim policy

fn graceBound(sim: *const Simulator) u16 {
    return switch (sim.config.policy.swim_grace) {
        .trust_client => swim_trusted,
        .ticks => |t| @min(t, swim_trusted - 1),
    };
}

pub fn clearSwimEvidence(sim: *const Simulator, state: *State) void {
    state.swim_water_contact = false;
    state.swim_grace_ticks = if (sim.config.policy.swim_grace == .trust_client) swim_trusted else 0;
}

// ------------------------------------------------------------------ travel

fn simulateMovement(sim: *Simulator, state: *State) Error!void {
    state.descend_through_block = false;
    inline for (.{ "x", "y", "z" }) |axis| {
        if (@abs(@field(state.vel, axis)) < 1e-8) @field(state.vel, axis) = 0;
    }

    const was_swim_pose = state.swimPose();
    const grace = sim.graceBound();
    if (state.swim_grace_ticks > grace) state.swim_grace_ticks = grace;

    try liquid.collectTouching(sim, state);
    const in_water = sim.scratch.water_len != 0;
    const in_lava = sim.scratch.lava_len != 0;
    state.swim_water_contact = in_water;
    if (was_swim_pose and !state.swimPose() and !state.gliding and state.riptide_ticks == 0) {
        try sim.restoreUprightPose(state);
    }
    if (in_water and state.swimming) {
        state.swim_grace_ticks = grace;
        setSwimmingPose(state);
    }

    try sim.travel(state, in_water, in_lava);

    const had_swim_pose = state.swimPose();
    if (in_water) {
        state.swim_grace_ticks = grace;
    } else if (state.swim_grace_ticks > 0 and grace != swim_trusted) {
        state.swim_grace_ticks -= 1;
    }
    if (had_swim_pose and !state.swimPose() and !state.gliding and state.riptide_ticks == 0) {
        try sim.restoreUprightPose(state);
    }
}

fn travel(sim: *Simulator, state: *State, in_water: bool, in_lava: bool) Error!void {
    if (!state.flying) try contact.attemptRiptide(sim, state, in_water);

    // Observed lava takes precedence over retained water evidence.
    const water_travel = in_water or (state.swimming and state.swim_grace_ticks > 0 and !in_lava);
    if (!state.flying and (water_travel or in_lava)) {
        if (!in_water and water_travel and sim.config.policy.swim_grace != .trust_client) sim.mech.swim_grace = true;
        sim.applyMotion(state);
        if (water_travel) {
            sim.mech.water = true;
            if (state.gliding) {
                try sim.stopGliding(state);
                state.glide_boost_ticks = 0;
            }
            try liquid.applyFlow(sim, state, sim.scratch.water[0..sim.scratch.water_len], .water);
            try liquid.travel(sim, state, .water, in_water);
        } else {
            sim.mech.lava = true;
            try liquid.applyFlow(sim, state, sim.scratch.lava[0..sim.scratch.lava_len], .lava);
            try liquid.travel(sim, state, .lava, true);
        }
        return;
    }

    const ground = try contact.groundFriction(sim, state);
    var block_friction: f32 = air_drag;
    var accel_speed = state.air_speed;
    if (state.on_ground) {
        sim.mech.ground = true;
        block_friction *= ground.friction;
        var accel_mul = ground.accel_friction_mul;
        if (state.equipment.soul_speed > 0 and ground.soul_speed_affected) accel_mul = 1;
        const accel_friction = (ground.friction * accel_mul) * air_drag;
        // Keep the native operation order. Dividing a precomputed cube by
        // friction cubed rounds differently, even on grass.
        const base_friction: f32 = air_drag * default_friction;
        const ratio = base_friction / accel_friction;
        accel_speed = ((state.movement_speed * ratio) * ratio) * ratio;
    } else {
        sim.mech.air = true;
    }

    if (state.gliding and state.effects.levitation != null) try sim.stopGliding(state);
    if (state.gliding) {
        if (state.equipment.elytra and !state.on_ground) {
            try sim.glideTick(state);
            return;
        }
        try sim.stopGliding(state);
    }

    sim.applyMotion(state);
    moveRelative(state, accel_speed);
    sim.note(.move_relative, state);

    const climber = try contact.climberFlags(sim, state);
    state.descend_through_block = climber.over_descendable and state.pressing_descend;
    if (state.descend_through_block) {
        state.vel.y = -contact.scaffolding_speed;
        sim.mech.scaffolding = true;
    }
    if (contact.applyClimbJump(state, climber)) {
        sim.mech.climb = true;
    } else if (try sim.attemptJump(state)) {
        sim.mech.jump = true;
        sim.note(.jump, state);
    }
    if (climber.climbable) sim.mech.climb = true;
    contact.applyLadderTravel(state, climber);
    sim.note(.climb, state);
    const scaffold_descend = state.descend_through_block and (climber.in_scaffolding or climber.over_scaffolding);
    const resets_fall = state.descend_through_block or climber.climbable or climber.in_scaffolding or climber.over_scaffolding;

    const stuck = applyStuckSpeed(state);
    if (stuck) sim.note(.stuck_speed, state);
    const edge = try sim.avoidEdge(state);

    var old_vel = state.vel;
    const old_y = state.pos.y;
    const move_boxes = try sim.moveWithCollisions(state);
    try sim.stopRiptideOnBlockCollision(state);
    updateFallDistance(state, old_y);
    if (resets_fall) state.fall_distance = 0;

    const landed = try contact.landingBlock(sim, state.boundingBox(), move_boxes);

    state.mov = state.vel;
    if (edge.clipped) {
        // Edge clipping shortens only this tick's displacement.
        state.vel.x = edge.retained.x;
        state.vel.z = edge.retained.z;
    }
    if (stuck) {
        state.vel = .zero;
        old_vel = .zero;
    }
    try sim.setPostCollisionMotion(state, old_vel, landed);
    const auto_climb = try contact.applyAutoClimb(sim, state);
    sim.note(.post_collision, state);

    var v = state.vel;
    if (scaffold_descend) {
        // Descending through scaffolding suppresses gravity but keeps drag.
        if (state.has_gravity) v.y *= vertical_drag;
    } else if (!auto_climb) {
        if (state.effects.levitation) |amp| {
            const target = levitation_speed * @as(f32, @floatFromInt(@as(i64, amp) + 1));
            v.y += (target - v.y) * 0.2;
        } else if (state.has_gravity) {
            v.y -= effectiveGravity(state, v);
            v.y *= vertical_drag;
        }
    }
    sim.note(.gravity, state);
    v.x = dampHorizontal(v.x, block_friction);
    v.z = dampHorizontal(v.z, block_friction);
    state.vel = v;
    sim.note(.friction, state);
    try contact.applyStandOnDamping(sim, state);
    sim.note(.stand_on, state);
    try contact.applyInsideBlockEffects(sim, state);
    sim.note(.inside_blocks, state);
}

fn glideTick(sim: *Simulator, state: *State) Error!void {
    sim.mech.glide = true;
    if (state.glide_boost_ticks > 0) sim.mech.glide_boost = true;
    state.on_ground = false;
    sim.applyMotion(state);
    simulateGlide(state);
    sim.note(.glide, state);
    const stuck = applyStuckSpeed(state);
    const old_y = state.pos.y;
    _ = try sim.moveWithCollisions(state);
    try sim.stopRiptideOnBlockCollision(state);
    updateFallDistance(state, old_y);
    state.mov = state.vel;
    if (stuck) state.vel = .zero;
    try contact.applyInsideBlockEffects(sim, state);
    sim.note(.inside_blocks, state);
}

/// Replaces velocity with a pending authoritative motion.
fn applyMotion(sim: *Simulator, state: *State) void {
    if (state.pending_motion) |m| {
        state.vel = m;
        sim.mech.motion = true;
        sim.note(.motion, state);
    }
}

pub fn moveRelative(state: *State, speed: f32) void {
    const imp = state.impulse;
    var force = imp.y * imp.y + imp.x * imp.x;
    if (force >= 1e-4) {
        force = speed / @max(@sqrt(force), 1.0);
        const mf = imp.y * force;
        const ms = imp.x * force;
        // DefaultMoveSystems::horizontalMovement uses sincosf rather than
        // the lookup table.
        const yaw = state.rotation.yaw * deg_to_rad;
        const s = math.sinf(yaw);
        const c = math.cosf(yaw);
        state.vel.x += ms * c - s * imp.y * force;
        state.vel.z += ms * s + mf * c;
    }
}

fn effectiveGravity(state: *const State, vel: Vec3) f32 {
    if (state.effects.slow_falling and vel.y < 0) return slow_falling_gravity;
    return state.gravity;
}

/// Horizontal drag, clearing components at or below float epsilon first.
fn dampHorizontal(v: f32, drag: f32) f32 {
    if (@abs(v) <= math.float_epsilon) return 0;
    return v * drag;
}

fn updateFallDistance(state: *State, old_y: f32) void {
    const dy = state.pos.y - old_y;
    if (dy < 0 and !state.on_ground) {
        state.fall_distance -= dy;
    } else if (dy > 0) {
        state.fall_distance = 0;
    }
    if (state.on_ground and state.fall_distance > 0) state.fall_distance = 0;
}

/// Applies and clears the queued stuck-speed multiplier.
pub fn applyStuckSpeed(state: *State) bool {
    const m = state.stuck_speed;
    if (m.lenSqr() <= 1e-7) return false;
    state.stuck_speed = .zero;
    if (state.no_clip) return false;
    state.vel = state.vel.mul(m);
    return true;
}

fn attemptJump(sim: *Simulator, state: *State) Error!bool {
    if (!state.jumping or !state.on_ground or state.jump_delay > 0) return false;
    var height = state.jump_height;
    if (try contact.jumpFactorHoney(sim, state)) height *= 0.6;
    state.vel = jumpImpulse(state.vel, height, state.rotation.yaw, state.sprinting);
    state.jump_delay = state_mod.jump_delay_ticks;
    return true;
}

/// Velocity change of an accepted jump. `yaw` is in degrees.
pub fn jumpImpulse(vel: Vec3, height: f32, yaw: f32, sprinting: bool) Vec3 {
    var v = vel;
    v.y = @max(height, v.y);
    if (sprinting) {
        const force = yaw * 0.017453292;
        v.x -= math.mcSin(force) * 0.2;
        v.z += math.mcCos(force) * 0.2;
    }
    return v;
}

const glide_fall_threshold: f32 = -0.5;

fn simulateGlide(state: *State) void {
    if (state.vel.y > glide_fall_threshold) state.fall_distance = 1;

    // The look vector uses the previous rotation plus the wrapped delta,
    // with pitch negated before the table lookup.
    const pi: f32 = std.math.pi;
    const yaw = math.wrappedAngle(state.last_rotation.yaw, state.rotation.yaw);
    const look_pitch = math.wrappedAngle(state.last_rotation.pitch, state.rotation.pitch) * -deg_to_rad;
    const yaw_angle = yaw * -deg_to_rad - pi;
    const look_pitch_cos = math.mcCos(look_pitch);
    const look_x = math.mcSin(yaw_angle) * -look_pitch_cos;
    const look_y = math.mcSin(look_pitch);
    const look_z = math.mcCos(yaw_angle) * -look_pitch_cos;

    const pitch = state.rotation.pitch * deg_to_rad;
    const pitch_cos = math.mcCos(pitch);
    const look_hz_sqr = look_x * look_x + look_z * look_z;
    const look_len = @sqrt(look_y * look_y + look_x * look_x + look_z * look_z);
    const sqr_pitch_cos = @min(look_len / 0.4, 1) * pitch_cos * pitch_cos;

    var v = state.vel;
    const vel_hz = @sqrt(v.x * v.x + v.z * v.z);
    const look_hz = @sqrt(look_hz_sqr);
    const gravity = if (state.effects.slow_falling) slow_falling_gravity else state.gravity;

    v.y -= (0.75 * sqr_pitch_cos - 1) * -gravity;
    if (look_hz_sqr > 0 and v.y < 0) {
        const accel = sqr_pitch_cos * -0.1 * v.y;
        v.x += look_x * accel / look_hz;
        v.y += accel;
        v.z += look_z * accel / look_hz;
    }
    if (pitch < 0) {
        const accel = math.mcSin(pitch) * vel_hz * -0.04;
        v.x -= accel * look_x / look_hz;
        v.y += 3.2 * accel;
        v.z -= accel * look_z / look_hz;
    }
    if (look_hz_sqr > 0) {
        v.x += (look_x / look_hz * vel_hz - v.x) * 0.1;
        v.z += (look_z / look_hz * vel_hz - v.z) * 0.1;
    }
    if (state.glide_boost_ticks > 0) {
        v.x = v.x + (1.5 * look_x - v.x) * 0.5 + look_x * 0.1;
        v.y = v.y + (look_y * 1.5 - v.y) * 0.5 + look_y * 0.1;
        v.z = v.z + (1.5 * look_z - v.z) * 0.5 + look_z * 0.1;
    }
    v.x *= 0.99;
    v.y *= 0.98;
    v.z *= 0.99;
    state.vel = v;
}

/// Clears blocked axes. A downward landing may rebound.
fn setPostCollisionMotion(sim: *Simulator, state: *State, old_vel: Vec3, landed: ?Block) Error!void {
    if (state.collide_y) state.vel.y = contact.restitution(sim, state, old_vel.y, landed);
    if (state.collide_x) state.vel.x = 0;
    if (state.collide_z) state.vel.z = 0;
}

// ------------------------------------------------------------------- poses

/// Chooses standing, sneaking, or crawling without entering a ceiling.
pub fn restoreUprightPose(sim: *Simulator, state: *State) Error!void {
    sim.mech.pose_change = true;
    const sz = &state.size;
    if (try sim.canFitHeight(state, sz.standing_height)) {
        state.sneaking = false;
        state.crawling = false;
        sz.height = sz.standing_height;
    } else if (try sim.canFitHeight(state, sz.sneaking_height)) {
        state.sneaking = true;
        state.crawling = false;
        sz.height = sz.sneaking_height;
    } else {
        state.sneaking = false;
        state.crawling = true;
        sz.height = sz.crawling_height;
    }
}

pub fn stopGliding(sim: *Simulator, state: *State) Error!void {
    state.gliding = false;
    if (state.swimPose() or state.riptide_ticks > 0) return;
    try sim.restoreUprightPose(state);
}

pub fn stopRiptideOnBlockCollision(sim: *Simulator, state: *State) Error!void {
    if (state.riptide_ticks > 0 and (state.collide_x or state.collide_z)) {
        state.riptide_ticks = 0;
        state.riptide_collision = false;
        if (!state.gliding and !state.swimPose()) try sim.restoreUprightPose(state);
    }
}

/// Whether an upright box of `height` at the current position is free.
fn canFitHeight(sim: *Simulator, state: *const State, height: f32) Error!bool {
    const scale = state.size.scale;
    const half = (state.size.width * 0.5) * scale;
    const h = height * scale;
    const shape = state.shape;
    const box = if (shape.valid and shape.pos.eql(state.pos) and shape.half_width == half and shape.height == h)
        shape.box
    else
        AABB.init(state.pos.x - half, state.pos.y, state.pos.z - half, state.pos.x + half, state.pos.y + h, state.pos.z + half);
    try sim.areaKnown(box);
    var ctx = sim.collisionContext(state);
    ctx.sneaking = false;
    ctx.descending = false;
    ctx.want_down = false;
    ctx.descend_through_block = false;
    return !(try sim.anyCollision(box, &ctx));
}

// --------------------------------------------------------------- collision

pub fn collisionContext(sim: *const Simulator, state: *const State) CollisionContext {
    _ = sim;
    return .{
        .position = state.pos,
        .sneaking = state.sneaking,
        .descending = state.pressing_descend,
        .want_down = state.want_down,
        .leather_boots = state.equipment.leather_boots,
        .descend_through_block = state.descend_through_block,
    };
}

pub const CellRange = struct {
    x0: i32,
    x1: i32,
    y0: i32,
    y1: i32,
    z0: i32,
    z1: i32,
};

/// Validates a query box and converts it to an inclusive cell range,
/// widening the bottom by `below` cells.
pub fn cellRange(sim: *const Simulator, q: AABB, below: i32, inclusive_ceil: bool) Error!CellRange {
    if (!q.isFinite()) return error.QueryLimit;
    inline for (.{ q.min.x, q.min.y, q.min.z, q.max.x, q.max.y, q.max.z }) |v| {
        if (!math.blockCoordInRange(v)) return error.QueryLimit;
    }
    const r: CellRange = .{
        .x0 = math.floorI(q.min.x),
        .x1 = if (inclusive_ceil) math.ceilI(q.max.x) else math.floorI(q.max.x),
        .y0 = math.floorI(q.min.y) -| below,
        .y1 = if (inclusive_ceil) math.ceilI(q.max.y) else math.floorI(q.max.y),
        .z0 = math.floorI(q.min.z),
        .z1 = if (inclusive_ceil) math.ceilI(q.max.z) else math.floorI(q.max.z),
    };
    if (r.x1 < r.x0 or r.y1 < r.y0 or r.z1 < r.z0) return r;
    const cells = (@as(i128, r.x1) - r.x0 + 1) * (@as(i128, r.y1) - r.y0 + 1) * (@as(i128, r.z1) - r.z0 + 1);
    if (cells > sim.config.max_query_cells) return error.QueryLimit;
    return r;
}

pub inline fn block(sim: *Simulator, pos: BlockPos) Error!Block {
    const c = &sim.cache;
    const i = BlockCache.slot(pos);
    if (c.stamps[i] == c.generation and c.keys[i].eql(pos)) return c.blocks[i];
    const b = sim.world.block(pos) orelse return error.Unloaded;
    if (!b.semantics.isValid()) return error.InvalidWorld;
    c.stamps[i] = c.generation;
    c.keys[i] = pos;
    c.blocks[i] = b;
    return b;
}

/// Ensures every cell overlapped by `q` is loaded.
pub fn areaKnown(sim: *Simulator, q: AABB) Error!void {
    var r = try sim.cellRange(q, 0, true);
    r.x1 = @max(r.x0, r.x1 -| 1);
    r.y1 = @max(r.y0, r.y1 -| 1);
    r.z1 = @max(r.z0, r.z1 -| 1);
    var x = r.x0;
    while (x <= r.x1) : (x += 1) {
        var z = r.z0;
        while (z <= r.z1) : (z += 1) {
            var y = r.y0;
            while (y <= r.y1) : (y += 1) _ = try sim.block(.init(x, y, z));
        }
    }
}

/// Collision boxes of a block in local space, resolving dynamic shapes.
pub fn cellShape(sim: *Simulator, pos: BlockPos, b: *const Block, ctx: *const CollisionContext) []const AABB {
    if (b.dynamic_shape) {
        if (sim.world.vtable.dynamic_shape) |resolve| {
            sim.mech.dynamic_shape = true;
            sim.scratch.dynamic.len = 0;
            resolve(sim.world.ptr, pos, b, ctx, &sim.scratch.dynamic);
            return sim.scratch.dynamic.slice();
        }
    }
    return b.shape;
}

/// Visits world-space collision boxes intersecting `q` in vanilla gathering
/// order. Returns true if the visitor stopped the scan.
fn scanBoxes(sim: *Simulator, q: AABB, ctx: *const CollisionContext, visitor: anytype) Error!bool {
    const r = try sim.cellRange(q, 1, false);
    var x = r.x0;
    while (x <= r.x1) : (x += 1) {
        var z = r.z0;
        while (z <= r.z1) : (z += 1) {
            var y = r.y0;
            while (y <= r.y1) : (y += 1) {
                const pos: BlockPos = .init(x, y, z);
                const b = try sim.block(pos);
                if (b.shape.len == 0 and !b.dynamic_shape) continue;
                const origin = pos.vec();
                for (sim.cellShape(pos, &b, ctx)) |local| {
                    const box = local.translate(origin);
                    if (box.isDegenerate() or !box.intersects(q)) continue;
                    if (try visitor.visit(box, pos)) return true;
                }
            }
        }
    }
    return false;
}

pub fn anyCollision(sim: *Simulator, q: AABB, ctx: *const CollisionContext) Error!bool {
    const Any = struct {
        fn visit(_: @This(), _: AABB, _: BlockPos) Error!bool {
            return true;
        }
    };
    return sim.scanBoxes(q, ctx, Any{});
}

/// Gathers colliding boxes into scratch memory. The result is valid until
/// the next gather.
pub fn gatherBoxes(sim: *Simulator, q: AABB, ctx: *const CollisionContext) Error![]const AABB {
    const Gather = struct {
        s: *Scratch,
        fn visit(g: @This(), box: AABB, pos: BlockPos) Error!bool {
            if (g.s.len == max_boxes) return error.QueryLimit;
            g.s.boxes[g.s.len] = box;
            g.s.owners[g.s.len] = pos;
            g.s.len += 1;
            return false;
        }
    };
    sim.scratch.len = 0;
    _ = try sim.scanBoxes(q, ctx, Gather{ .s = &sim.scratch });
    return sim.scratch.boxes[0..sim.scratch.len];
}

/// Recovers contact endpoints for an externally anchored position once the
/// area is loaded. Known sweeps and native pose changes keep their geometry.
fn prepareCollisionBox(sim: *Simulator, state: *State) void {
    const shape = state.shape;
    const d = state.dimensions();
    const same = shape.half_width == d.half_width and shape.height == d.height;
    if (shape.valid and same and shape.pos.eql(state.pos)) return;
    const box = state.boxAt(state.pos);
    if (shape.valid and !same) {
        // Native resizing rebuilds all endpoints.
        state.rememberBox(box);
        return;
    }
    sim.areaKnown(box) catch return;
    const ctx = sim.collisionContext(state);
    const boxes = sim.gatherBoxes(box, &ctx) catch return;
    state.rememberBox(recoverRoundedContacts(box, state.pos, boxes));
}

/// Restores horizontal contact faces only when the box's f32 centre still
/// equals the supplied position. Combined faces are checked again so the
/// result does not depend on box order.
pub fn recoverRoundedContacts(box: AABB, pos: Vec3, boxes: []const AABB) AABB {
    var low = box.min;
    var high = box.max;
    for (boxes) |other| {
        if (!box.intersects(other)) continue;
        inline for (.{ "x", "z" }) |a| {
            const omin = @field(box.min, a);
            const omax = @field(box.max, a);
            const p = @field(pos, a);
            var face = @field(other.max, a);
            if (face > omin and face < omax and (face + omax) * 0.5 == p) @field(low, a) = @max(@field(low, a), face);
            face = @field(other.min, a);
            if (face < omax and face > omin and (omin + face) * 0.5 == p) @field(high, a) = @min(@field(high, a), face);
        }
    }
    inline for (.{ "x", "z" }) |a| {
        if (@field(low, a) >= @field(high, a) or (@field(low, a) + @field(high, a)) * 0.5 != @field(pos, a)) {
            @field(low, a) = @field(box.min, a);
            @field(high, a) = @field(box.max, a);
        }
    }
    return .{ .min = low, .max = high };
}

const StepResult = struct { box: AABB, vel: Vec3 };

/// The client's auto-step sweep over boxes that start below the original
/// box top.
fn calculateAutoStep(original: AABB, vel: Vec3, boxes: []const AABB, one_way: bool) StepResult {
    var up: Vec3 = .init(0, step_height, 0);
    var xv: Vec3 = .init(vel.x, 0, 0);
    var zv: Vec3 = .init(0, 0, vel.z);
    var bb = original;
    var i = boxes.len;
    while (i > 0) : (i -= 1) {
        if (boxes[i - 1].min.y < original.max.y) up = clip(boxes[i - 1], bb, up, one_way, null);
    }
    bb = bb.translate(up);
    i = boxes.len;
    while (i > 0) : (i -= 1) {
        if (boxes[i - 1].min.y < original.max.y) xv = clip(boxes[i - 1], bb, xv, one_way, null);
    }
    bb = bb.translate(xv);
    i = boxes.len;
    while (i > 0) : (i -= 1) {
        if (boxes[i - 1].min.y < original.max.y) zv = clip(boxes[i - 1], bb, zv, one_way, null);
    }
    bb = bb.translate(zv);
    var down = up.scale(-1);
    i = boxes.len;
    while (i > 0) : (i -= 1) {
        if (boxes[i - 1].min.y < original.max.y) down = clip(boxes[i - 1], bb, down, one_way, null);
    }
    bb = bb.translate(down);
    return .{ .box = bb, .vel = up.add(xv).add(zv).add(down) };
}

fn clip(stationary: AABB, moving: AABB, vel: Vec3, one_way: bool, penetration: ?*Vec3) Vec3 {
    const c = aabb_mod.clipCollide(stationary, moving, vel);
    if (penetration) |p| {
        if (p.get(c.axis) < c.penetration) p.set(c.axis, c.penetration);
    }
    return if (one_way) c.clipped else c.depenetrating;
}

/// Resolves this tick's displacement against the world. Returns the boxes
/// the move considered, valid until the next gather.
pub fn moveWithCollisions(sim: *Simulator, state: *State) Error![]const AABB {
    var bb = state.boundingBox();
    const original = bb;
    const cur = state.vel;
    const ctx = sim.collisionContext(state);
    const boxes = try sim.gatherBoxes(bb.extend(cur), &ctx);

    const one_way = state.stuck_in_collider;
    var pen: Vec3 = .zero;
    var yv: Vec3 = .init(0, cur.y, 0);
    var xv: Vec3 = .init(cur.x, 0, 0);
    var zv: Vec3 = .init(0, 0, cur.z);
    var i = boxes.len;
    while (i > 0) : (i -= 1) yv = clip(boxes[i - 1], bb, yv, one_way, &pen);
    bb = bb.translate(yv);
    i = boxes.len;
    while (i > 0) : (i -= 1) xv = clip(boxes[i - 1], bb, xv, one_way, &pen);
    bb = bb.translate(xv);
    i = boxes.len;
    while (i > 0) : (i -= 1) zv = clip(boxes[i - 1], bb, zv, one_way, &pen);
    bb = bb.translate(zv);
    sim.note(.collide, state);

    var vel = yv.add(xv).add(zv);
    const has_pen = pen.lenSqr() >= 9.999999999999999e-12;
    if (has_pen) sim.mech.depenetration = true;
    state.stuck_in_collider = state.penetrated_last_frame and has_pen;
    state.penetrated_last_frame = has_pen;

    const x_hit = cur.x != vel.x;
    const z_hit = cur.z != vel.z;
    const grounded = state.on_ground or (cur.y != vel.y and cur.y < 0);
    if (grounded and (x_hit or z_hit)) {
        const step = calculateAutoStep(original, cur, boxes, one_way);
        if (!(try sim.anyCollision(step.box, &ctx)) and math.hzLenSqr(vel) < math.hzLenSqr(step.vel)) {
            const accept = if (sim.config.policy.step_client_tiebreak) |threshold| blk: {
                // Server reconciliation policy, not vanilla movement.
                const step_dist = step.box.bottomCenter().sub(state.reported.pos).len();
                const plain_dist = bb.bottomCenter().sub(state.reported.pos).len();
                break :blk plain_dist > threshold or step_dist <= plain_dist;
            } else true;
            if (accept) {
                vel = step.vel;
                bb = step.box;
                sim.mech.step = true;
                sim.note(.step, state);
            }
        }
    }

    const end = bb.bottomCenter();
    state.sprint_movement_blocked = sprintMovementBlocked(cur, end.sub(state.pos));
    state.pos = end;
    state.rememberBox(bb);

    const y_hit = @abs(cur.y - vel.y) > math.float_epsilon;
    state.collide_x = @abs(cur.x - vel.x) > math.float_epsilon;
    state.collide_y = y_hit;
    state.collide_z = @abs(cur.z - vel.z) > math.float_epsilon;
    // Ground contact follows the requested vertical movement, including
    // after a step: a step taken mid-jump stays airborne for a tick.
    state.on_ground = (y_hit and cur.y < 0) or (state.on_ground and !y_hit and cur.y == 0);
    try contact.updateSupportingBlock(sim, state, cur);
    state.vel = vel;
    return sim.scratch.boxes[0..sim.scratch.len];
}

/// Vanilla's stalled dominant-axis check. `actual` is the displacement the
/// request produced.
pub fn sprintMovementBlocked(requested: Vec3, actual: Vec3) bool {
    const min_movement: f32 = 0.00005;
    const x = @abs(requested.x);
    const z = @abs(requested.z);
    return (x > z and @abs(actual.x) < min_movement) or (z > x and @abs(actual.z) < min_movement);
}

pub const edge_drop: f32 = -step_height * @as(f32, 1.01);

const EdgeResult = struct { retained: Vec3 = .zero, clipped: bool = false };

/// Clips a grounded sneaking move to supported ground.
fn avoidEdge(sim: *Simulator, state: *State) Error!EdgeResult {
    if (!state.sneaking or !state.on_ground) return .{};
    sim.mech.sneak_edge = true;
    const offset: f32 = 0.05;
    const drop = edge_drop;
    const max_iter = 1000;

    const old = state.vel;
    const bb = state.boundingBox().growVec(.init(-0.025, 0, -0.025));
    const ctx = sim.collisionContext(state);
    var xm = old.x;
    var zm = old.z;

    var i: u32 = 0;
    while (i < max_iter and xm != 0 and !(try sim.anyCollision(bb.translate(.init(xm, drop, 0)), &ctx))) : (i += 1) xm = edgeStep(xm, offset);
    if (i == max_iter) xm = 0;
    i = 0;
    while (i < max_iter and zm != 0 and !(try sim.anyCollision(bb.translate(.init(0, drop, zm)), &ctx))) : (i += 1) zm = edgeStep(zm, offset);
    if (i == max_iter) zm = 0;
    i = 0;
    while (i < max_iter and xm != 0 and zm != 0 and !(try sim.anyCollision(bb.translate(.init(xm, drop, zm)), &ctx))) : (i += 1) {
        xm = edgeStep(xm, offset);
        zm = edgeStep(zm, offset);
    }
    if (i == max_iter) {
        xm = 0;
        zm = 0;
    }

    // Velocity survives the clip unless an axis is clipped to rest.
    var retained = old;
    if (@abs(xm) <= math.float_epsilon) retained.x = 0;
    if (@abs(zm) <= math.float_epsilon) retained.z = 0;
    state.vel.x = xm;
    state.vel.z = zm;
    sim.note(.sneak_edge, state);
    return .{ .retained = retained, .clipped = true };
}

fn edgeStep(v: f32, offset: f32) f32 {
    if (v < offset and v >= -offset) return 0;
    return if (v > 0) v - offset else v + offset;
}

test {
    _ = @import("tests.zig");
}
