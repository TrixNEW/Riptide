const std = @import("std");
const math = @import("math.zig");
const AABB = @import("aabb.zig").AABB;
const BlockPos = @import("world.zig").BlockPos;
const Vec3 = math.Vec3;
const Vec2 = math.Vec2;

pub const default_jump_strength: f32 = 0.42;
pub const default_gravity: f32 = 0.08;
pub const walk_air_speed: f32 = 0.02;
pub const sprint_air_speed: f32 = 0.026;
pub const jump_delay_ticks = 10;
pub const glide_boost_ticks = 20;
pub const riptide_ticks = 20;

pub const GameMode = enum(u8) { survival, creative, adventure, spectator };

pub const Rotation = extern struct {
    pitch: f32 = 0,
    head_yaw: f32 = 0,
    yaw: f32 = 0,

    pub fn isFinite(r: Rotation) bool {
        return std.math.isFinite(r.pitch) and std.math.isFinite(r.head_yaw) and std.math.isFinite(r.yaw);
    }
};

pub const Effects = struct {
    jump_boost: ?i32 = null,
    levitation: ?i32 = null,
    slow_falling: bool = false,
    weaving: bool = false,
};

pub const Equipment = struct {
    depth_strider: u8 = 0,
    soul_speed: u8 = 0,
    swift_sneak: u8 = 0,
    riptide: u8 = 0,
    leather_boots: bool = false,
    elytra: bool = false,
};

pub const Size = extern struct {
    width: f32 = 0.6,
    height: f32 = 1.8,
    scale: f32 = 1,
    standing_height: f32 = 1.8,
    sneaking_height: f32 = 1.49,
    crawling_height: f32 = 0.6,

    fn isValid(s: Size) bool {
        for ([_]f32{ s.width, s.height, s.scale, s.standing_height, s.sneaking_height, s.crawling_height }) |v| {
            if (!(v > 0 and v <= 64)) return false;
        }
        return true;
    }
};

pub const Teleport = struct {
    target: Vec3,
    remaining: u32,
    smoothed: bool,
};

pub const Reported = struct {
    pos: Vec3 = .zero,
    vel: Vec3 = .zero,
    last_pos: Vec3 = .zero,
    horizontal_collision: bool = false,
    vertical_collision: bool = false,
    toggled_fly: bool = false,
};

pub const CollisionShape = struct {
    box: AABB = .init(0, 0, 0, 0, 0, 0),
    pos: Vec3 = .zero,
    half_width: f32 = 0,
    height: f32 = 0,
    valid: bool = false,
};

pub const State = struct {
    pos: Vec3 = .zero,
    vel: Vec3 = .zero,
    mov: Vec3 = .zero,
    rotation: Rotation = .{},
    last_rotation: Rotation = .{},

    on_ground: bool = false,
    collide_x: bool = false,
    collide_y: bool = false,
    collide_z: bool = false,
    fall_distance: f32 = 0,
    supporting_block: ?BlockPos = null,

    size: Size = .{},
    sneaking: bool = false,
    crawling: bool = false,
    swimming: bool = false,
    gliding: bool = false,
    swim_amount: f32 = 0,

    sprinting: bool = false,
    server_sprint: bool = false,
    server_sprint_applied: bool = true,
    server_updated_speed: bool = false,

    movement_speed: f32 = 0.1,
    default_movement_speed: f32 = 0.1,
    air_speed: f32 = walk_air_speed,
    jump_strength: f32 = default_jump_strength,
    gravity: f32 = default_gravity,
    has_gravity: bool = true,
    underwater_speed: f32 = 0.02,
    lava_speed: f32 = 0.02,
    swim_speed_multiplier: f32 = 1,
    dolphin_boost_ticks: u32 = 0,

    effects: Effects = .{},
    equipment: Equipment = .{},

    game_mode: GameMode = .survival,
    flying: bool = false,
    trust_fly_status: bool = false,
    just_disabled_flight: bool = false,
    no_clip: bool = false,
    immobile: bool = false,
    ready: bool = true,
    alive: bool = true,
    in_vehicle: bool = false,

    jump_delay: u8 = 0,
    glide_boost_ticks: u8 = 0,
    ticks_since_can_slowdown: u32 = 0,

    riptide_ticks: u8 = 0,
    riptide_ready: bool = false,
    riptide_collision: bool = false,
    riptide_in_rain: bool = false,
    starting_spin_attack: bool = false,

    swim_grace_ticks: u16 = 0,
    stopped_swimming_this_tick: bool = false,

    reported: Reported = .{},

    pending_motion: ?Vec3 = null,
    teleport: ?Teleport = null,
    firework_pending: bool = false,

    jumping: bool = false,
    pressing_jump: bool = false,
    pressing_ascend: bool = false,
    pressing_descend: bool = false,
    effective_jumping: bool = false,
    want_down: bool = false,
    want_down_slow: bool = false,
    impulse: Vec2 = .{},
    jump_height: f32 = default_jump_strength,

    stuck_speed: Vec3 = .zero,
    penetrated_last_frame: bool = false,
    stuck_in_collider: bool = false,
    swim_water_contact: bool = false,
    descend_through_block: bool = false,
    sprint_movement_blocked: bool = false,
    shape: CollisionShape = .{},

    pub fn queueMotion(s: *State, vel: Vec3) void {
        s.pending_motion = vel;
    }

    pub fn queueFireworkBoost(s: *State) void {
        s.firework_pending = true;
    }

    pub fn queueTeleport(s: *State, target: Vec3, smoothed_ticks: u32) void {
        s.teleport = .{
            .target = target,
            .remaining = if (smoothed_ticks == 0) 1 else smoothed_ticks +| 1,
            .smoothed = smoothed_ticks != 0,
        };
    }

    pub fn setPosition(s: *State, pos: Vec3) void {
        s.pos = pos;
    }

    pub fn swimPose(s: *const State) bool {
        return s.swimming and (s.swim_water_contact or s.swim_grace_ticks > 0);
    }

    pub fn compactPose(s: *const State) bool {
        return s.swimPose() or s.gliding or s.riptide_ticks > 0;
    }

    pub fn dimensions(s: *const State) struct { half_width: f32, height: f32 } {
        const scale = s.size.scale;
        const height = if (s.compactPose()) s.size.width * scale else s.size.height * scale;
        return .{ .half_width = (s.size.width * 0.5) * scale, .height = height };
    }

    pub fn boxAt(s: *const State, pos: Vec3) AABB {
        const d = s.dimensions();
        return .init(pos.x - d.half_width, pos.y, pos.z - d.half_width, pos.x + d.half_width, pos.y + d.height, pos.z + d.half_width);
    }

    pub fn boundingBox(s: *const State) AABB {
        const d = s.dimensions();
        const shape = s.shape;
        if (shape.valid and shape.pos.eql(s.pos) and shape.half_width == d.half_width and shape.height == d.height) return shape.box;
        return s.boxAt(s.pos);
    }

    pub fn rememberBox(s: *State, box: AABB) void {
        const d = s.dimensions();
        s.shape = .{ .box = box, .pos = s.pos, .half_width = d.half_width, .height = d.height, .valid = true };
    }

    pub fn eyePosition(s: *const State) Vec3 {
        const offset: f32 = if (s.swimPose() or s.crawling or s.gliding or s.riptide_ticks > 0)
            0.4
        else if (s.sneaking)
            1.27
        else
            1.62;
        return s.pos.add(.init(0, offset * s.size.scale, 0));
    }

    pub fn isValid(s: *const State) bool {
        const vecs = [_]Vec3{ s.pos, s.vel, s.mov, s.stuck_speed, s.reported.pos, s.reported.vel, s.reported.last_pos };
        for (vecs) |v| if (!v.isFinite()) return false;
        if (s.pending_motion) |m| if (!m.isFinite()) return false;
        if (s.teleport) |t| if (!t.target.isFinite() or t.remaining == 0) return false;
        if (!s.rotation.isFinite() or !s.last_rotation.isFinite() or !s.impulse.isFinite()) return false;
        if (!s.size.isValid()) return false;
        const scalars = [_]f32{
            s.fall_distance, s.swim_amount,   s.movement_speed,        s.default_movement_speed,
            s.air_speed,     s.jump_strength, s.gravity,               s.underwater_speed,
            s.lava_speed,    s.jump_height,   s.swim_speed_multiplier,
        };
        for (scalars) |v| if (!std.math.isFinite(v)) return false;
        return true;
    }
};

pub const Input = struct {
    move: Vec2 = .{},
    move_is_raw: bool = false,
    rotation: Rotation = .{},
    reported_pos: Vec3 = .zero,
    reported_vel: Vec3 = .zero,
    item_use_modifier: ?f32 = null,
    flags: Flags = .{},

    pub const Flags = packed struct(u32) {
        horizontal_collision: bool = false,
        vertical_collision: bool = false,
        start_flying: bool = false,
        stop_flying: bool = false,
        start_sprinting: bool = false,
        stop_sprinting: bool = false,
        sprint_down: bool = false,
        start_sneaking: bool = false,
        stop_sneaking: bool = false,
        sneak_down: bool = false,
        sneaking: bool = false,
        start_jumping: bool = false,
        jumping: bool = false,
        auto_jumping_in_water: bool = false,
        ascend_block: bool = false,
        descend_block: bool = false,
        start_swimming: bool = false,
        stop_swimming: bool = false,
        want_down: bool = false,
        want_down_slow: bool = false,
        start_crawling: bool = false,
        stop_crawling: bool = false,
        start_gliding: bool = false,
        stop_gliding: bool = false,
        using_consumable: bool = false,
        using_item: bool = false,
        using_spear: bool = false,
        inventory_action: bool = false,
        start_spin_attack: bool = false,
        stop_spin_attack: bool = false,
        _pad: u2 = 0,
    };

    pub fn isValid(i: *const Input) bool {
        if (i.item_use_modifier) |m| if (!(m >= 0 and m <= 1)) return false;
        return i.move.isFinite() and i.rotation.isFinite() and i.reported_pos.isFinite() and i.reported_vel.isFinite();
    }
};

pub const SwimGrace = union(enum) {
    trust_client,
    ticks: u16,
};

pub const Policy = struct {
    swim_grace: SwimGrace,
    step_client_tiebreak: ?f32,

    pub const vanilla: Policy = .{ .swim_grace = .trust_client, .step_client_tiebreak = null };
    pub const hardened: Policy = .{ .swim_grace = .{ .ticks = 10 }, .step_client_tiebreak = null };
};

pub const SprintTiming = enum {
    modern,
    legacy,
};

pub const Config = struct {
    policy: Policy,
    sprint_timing: SprintTiming = .modern,
    max_query_cells: u32 = 8192,
};

pub const Outcome = enum(u8) {
    normal,
    teleport,
    client_authoritative,
    unloaded,
    immobile,
    mounted,
    invalid_input,
    invalid_world,
    query_limit,
};

pub const Mechanics = packed struct(u32) {
    ground: bool = false,
    air: bool = false,
    step: bool = false,
    sneak_edge: bool = false,
    depenetration: bool = false,
    water: bool = false,
    lava: bool = false,
    liquid_flow: bool = false,
    swim_grace: bool = false,
    glide: bool = false,
    glide_boost: bool = false,
    motion: bool = false,
    jump: bool = false,
    climb: bool = false,
    scaffolding: bool = false,
    powder_snow: bool = false,
    cobweb: bool = false,
    sweet_berry_bush: bool = false,
    honey: bool = false,
    bounce: bool = false,
    bubble_column: bool = false,
    riptide: bool = false,
    dynamic_shape: bool = false,
    pose_change: bool = false,
    _pad: u8 = 0,

    pub fn confidence(m: Mechanics) Confidence {
        const Bits = @typeInfo(Mechanics).@"struct".backing_integer.?;
        const bits: Bits = @bitCast(m);
        const uncertain_bits: Bits = @bitCast(Mechanics{
            .swim_grace = true,
            .glide_boost = true,
            .dynamic_shape = true,
            .liquid_flow = true,
            .riptide = true,
        });
        const decompiled_bits: Bits = @bitCast(Mechanics{
            .ground = true,
            .air = true,
            .depenetration = true,
            .climb = true,
            .sneak_edge = true,
        });
        if (bits & uncertain_bits != 0) return .uncertain;
        // BedSim drops motion while gliding. Applying it is unverified.
        if (m.glide and m.motion) return .uncertain;
        if (bits & ~decompiled_bits != 0) return .ported;
        return .decompiled;
    }
};

pub const Confidence = enum(u8) {
    decompiled,
    ported,
    uncertain,
};

pub const Result = struct {
    outcome: Outcome,
    pos: Vec3 = .zero,
    vel: Vec3 = .zero,
    mov: Vec3 = .zero,
    on_ground: bool = false,
    collide_x: bool = false,
    collide_y: bool = false,
    collide_z: bool = false,
    position_delta: Vec3 = .zero,
    velocity_delta: Vec3 = .zero,
    input_move: Vec2 = .{},
    sprint_movement_blocked: bool = false,
    mechanics: Mechanics = .{},

    pub fn confidence(r: Result) Confidence {
        return r.mechanics.confidence();
    }
};

pub const Correction = struct {
    mode: Mode = .authoritative,
    position_threshold: f32,
    velocity_threshold: f32,

    pub const Mode = enum {
        authoritative,
        permissive,
        passive,
    };

    pub fn needed(c: Correction, r: Result) bool {
        if (r.outcome == .invalid_input or r.outcome == .invalid_world) return c.mode != .passive;
        const pos = c.position_threshold > 0 and r.position_delta.len() > c.position_threshold;
        const vel = c.velocity_threshold > 0 and r.velocity_delta.len() > c.velocity_threshold;
        return switch (c.mode) {
            .passive => false,
            .permissive => pos,
            .authoritative => pos or vel,
        };
    }
};

test "teleport queue" {
    var s: State = .{};
    s.queueTeleport(.init(1, 2, 3), 0);
    try std.testing.expectEqual(@as(u32, 1), s.teleport.?.remaining);
    s.queueTeleport(.init(1, 2, 3), 2);
    try std.testing.expectEqual(@as(u32, 3), s.teleport.?.remaining);
}

test "state validation rejects non-finite values" {
    var s: State = .{};
    try std.testing.expect(s.isValid());
    s.vel.y = std.math.nan(f32);
    try std.testing.expect(!s.isValid());
    s = .{};
    s.size.height = 0;
    try std.testing.expect(!s.isValid());
}

test "confidence classification" {
    try std.testing.expectEqual(Confidence.decompiled, (Mechanics{ .ground = true }).confidence());
    try std.testing.expectEqual(Confidence.ported, (Mechanics{ .ground = true, .water = true }).confidence());
    try std.testing.expectEqual(Confidence.uncertain, (Mechanics{ .riptide = true }).confidence());
    try std.testing.expectEqual(Confidence.uncertain, (Mechanics{ .glide = true, .motion = true }).confidence());
}
