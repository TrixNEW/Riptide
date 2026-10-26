//! C interface. See include/riptide.h for the contract.

const std = @import("std");
const rt = @import("root.zig");

const gpa = std.heap.smp_allocator;

pub const Vec3 = rt.Vec3;

pub const Block = extern struct {
    shape: ?[*]const rt.AABB,
    shape_len: u32,
    friction: f32,
    accel_friction_mul: f32,
    flags: u32,
    kind: u8,
    bounce: u8,
    inside: u8,
    traversal: u8,
    liquid: u8,
    liquid_level: u8,
    solid_faces: u8,
    bubble: u8,
    bubble_surface: i8,
    reserved: [3]u8,
};

pub const CollisionContext = extern struct {
    position: Vec3,
    sneaking: u8,
    descending: u8,
    want_down: u8,
    leather_boots: u8,
    descend_through_block: u8,
    reserved: [3]u8 = @splat(0),
};

pub const BlockFn = *const fn (?*anyopaque, i32, i32, i32, *Block) callconv(.c) c_int;
pub const DynamicShapeFn = *const fn (?*anyopaque, i32, i32, i32, *const CollisionContext, [*]rt.AABB, u32) callconv(.c) u32;

pub const World = extern struct {
    user: ?*anyopaque,
    block: ?BlockFn,
    dynamic_shape: ?DynamicShapeFn,
};

pub const Config = extern struct {
    swim_grace: u8,
    legacy_sprint: u8,
    swim_grace_ticks: u16,
    step_client_tiebreak: f32,
    max_query_cells: u32,
};

pub const Input = extern struct {
    move_x: f32,
    move_y: f32,
    pitch: f32,
    head_yaw: f32,
    yaw: f32,
    reported_pos: Vec3,
    reported_vel: Vec3,
    item_use_modifier: f32,
    flags: u32,
    move_is_raw: u8,
    reserved: [3]u8,
};

pub const Result = extern struct {
    pos: Vec3,
    vel: Vec3,
    mov: Vec3,
    position_delta: Vec3,
    velocity_delta: Vec3,
    mechanics: u32,
    outcome: u8,
    confidence: u8,
    on_ground: u8,
    collide_x: u8,
    collide_y: u8,
    collide_z: u8,
    sprint_movement_blocked: u8,
    reserved: u8 = 0,
};

pub const StateView = extern struct {
    pos: Vec3,
    vel: Vec3,
    pitch: f32,
    head_yaw: f32,
    yaw: f32,
    width: f32,
    height: f32,
    scale: f32,
    standing_height: f32,
    sneaking_height: f32,
    crawling_height: f32,
    movement_speed: f32,
    default_movement_speed: f32,
    jump_strength: f32,
    gravity: f32,
    underwater_speed: f32,
    lava_speed: f32,
    swim_speed_multiplier: f32,
    fall_distance: f32,
    jump_boost: i32,
    levitation: i32,
    dolphin_boost_ticks: u32,
    on_ground: u8,
    sneaking: u8,
    crawling: u8,
    swimming: u8,
    gliding: u8,
    sprinting: u8,
    has_gravity: u8,
    slow_falling: u8,
    weaving: u8,
    depth_strider: u8,
    soul_speed: u8,
    swift_sneak: u8,
    riptide: u8,
    leather_boots: u8,
    elytra: u8,
    game_mode: u8,
    flying: u8,
    trust_fly_status: u8,
    no_clip: u8,
    immobile: u8,
    ready: u8,
    alive: u8,
    in_vehicle: u8,
    server_sprint: u8,
    server_updated_speed: u8,
    riptide_in_rain: u8,
    reserved: [2]u8 = @splat(0),
};

const CSimulator = struct {
    sim: rt.Simulator,
    world: World,
};

const invalid: rt.Block = .{ .semantics = .{ .friction = std.math.nan(f32) } };

fn lookup(ptr: *anyopaque, pos: rt.BlockPos) ?rt.Block {
    const cs: *CSimulator = @ptrCast(@alignCast(ptr));
    var b: Block = std.mem.zeroes(Block);
    b.friction = 0.6;
    b.accel_friction_mul = 1;
    b.bubble_surface = -1;
    if (cs.world.block.?(cs.world.user, pos.x, pos.y, pos.z, &b) == 0) return null;
    return convert(&b);
}

/// Converts a C block. Malformed values produce semantics the simulator
/// rejects as `invalid_world`.
fn convert(b: *const Block) rt.Block {
    if (b.kind > 2 or b.bounce > 2 or b.inside > 2 or b.traversal > 2 or b.liquid > 2 or
        b.liquid_level > 7 or b.bubble > 2 or b.bubble_surface < -1 or b.bubble_surface > 1) return invalid;
    if (b.shape_len != 0 and b.shape == null) return invalid;
    const f = b.flags;
    const bit = struct {
        fn on(flags: u32, comptime n: u5) bool {
            return flags & (1 << n) != 0;
        }
    }.on;
    return .{
        .kind = @fromBackingInt(@intCast(b.kind)),
        .shape = if (b.shape_len == 0) &.{} else b.shape.?[0..b.shape_len],
        .semantics = .{
            .friction = b.friction,
            .accel_friction_mul = b.accel_friction_mul,
            .soul_speed_affected = bit(f, 0),
            .climbable = bit(f, 1),
            .cobweb = bit(f, 2),
            .honey = bit(f, 3),
            .carpet = bit(f, 4),
            .bounce = @fromBackingInt(@intCast(b.bounce)),
            .inside = @fromBackingInt(@intCast(b.inside)),
            .traversal = @fromBackingInt(@intCast(b.traversal)),
        },
        .liquid = if (b.liquid == 0) null else .{
            .kind = if (b.liquid == 1) .water else .lava,
            .level = @intCast(b.liquid_level),
            .falling = bit(f, 7),
        },
        .solid_faces = @bitCast(@as(u4, @truncate(b.solid_faces))),
        .flow_barrier = bit(f, 5),
        .bubble = @fromBackingInt(@intCast(b.bubble)),
        .bubble_surface = if (b.bubble_surface < 0) null else b.bubble_surface == 1,
        .dynamic_shape = bit(f, 6),
    };
}

fn dynamicShape(ptr: *anyopaque, pos: rt.BlockPos, _: *const rt.Block, ctx: *const rt.CollisionContext, out: *rt.ShapeBuffer) void {
    const cs: *CSimulator = @ptrCast(@alignCast(ptr));
    const resolve = cs.world.dynamic_shape orelse return;
    const c: CollisionContext = .{
        .position = ctx.position,
        .sneaking = @intFromBool(ctx.sneaking),
        .descending = @intFromBool(ctx.descending),
        .want_down = @intFromBool(ctx.want_down),
        .leather_boots = @intFromBool(ctx.leather_boots),
        .descend_through_block = @intFromBool(ctx.descend_through_block),
    };
    const n = resolve(cs.world.user, pos.x, pos.y, pos.z, &c, &out.boxes, rt.ShapeBuffer.max_dynamic_boxes);
    out.len = @intCast(@min(n, rt.ShapeBuffer.max_dynamic_boxes));
}

const vtable: rt.World.VTable = .{ .block = lookup, .dynamic_shape = dynamicShape };

fn config(c: *const Config) ?rt.Config {
    if (c.swim_grace > 1) return null;
    const tiebreak: ?f32 = if (std.math.isNan(c.step_client_tiebreak)) null else c.step_client_tiebreak;
    if (tiebreak) |t| if (!(t >= 0 and t < std.math.inf(f32))) return null;
    return .{
        .policy = .{
            .swim_grace = if (c.swim_grace == 0) .trust_client else .{ .ticks = c.swim_grace_ticks },
            .step_client_tiebreak = tiebreak,
        },
        .sprint_timing = if (c.legacy_sprint != 0) .legacy else .modern,
        .max_query_cells = if (c.max_query_cells == 0) 8192 else c.max_query_cells,
    };
}

export fn rt_version() [*:0]const u8 {
    return rt.version;
}

export fn rt_simulator_create(world: World, c: ?*const Config) ?*CSimulator {
    if (world.block == null) return null;
    const cfg = config(c orelse return null) orelse return null;
    const cs = gpa.create(CSimulator) catch return null;
    cs.* = .{ .sim = .init(.{ .ptr = cs, .vtable = &vtable }, cfg), .world = world };
    return cs;
}

export fn rt_simulator_destroy(cs: ?*CSimulator) void {
    gpa.destroy(cs orelse return);
}

export fn rt_simulator_set_world(cs: *CSimulator, world: World) void {
    if (world.block == null) return;
    cs.world = world;
}

export fn rt_state_create(pos: Vec3) ?*rt.State {
    const s = gpa.create(rt.State) catch return null;
    s.* = .{ .pos = pos };
    return s;
}

export fn rt_state_clone(s: *const rt.State) ?*rt.State {
    const c = gpa.create(rt.State) catch return null;
    c.* = s.*;
    return c;
}

export fn rt_state_destroy(s: ?*rt.State) void {
    gpa.destroy(s orelse return);
}

export fn rt_state_get(s: *const rt.State, out: *StateView) void {
    out.* = .{
        .pos = s.pos,
        .vel = s.vel,
        .pitch = s.rotation.pitch,
        .head_yaw = s.rotation.head_yaw,
        .yaw = s.rotation.yaw,
        .width = s.size.width,
        .height = s.size.height,
        .scale = s.size.scale,
        .standing_height = s.size.standing_height,
        .sneaking_height = s.size.sneaking_height,
        .crawling_height = s.size.crawling_height,
        .movement_speed = s.movement_speed,
        .default_movement_speed = s.default_movement_speed,
        .jump_strength = s.jump_strength,
        .gravity = s.gravity,
        .underwater_speed = s.underwater_speed,
        .lava_speed = s.lava_speed,
        .swim_speed_multiplier = s.swim_speed_multiplier,
        .fall_distance = s.fall_distance,
        .jump_boost = s.effects.jump_boost orelse -1,
        .levitation = s.effects.levitation orelse -1,
        .dolphin_boost_ticks = s.dolphin_boost_ticks,
        .on_ground = @intFromBool(s.on_ground),
        .sneaking = @intFromBool(s.sneaking),
        .crawling = @intFromBool(s.crawling),
        .swimming = @intFromBool(s.swimming),
        .gliding = @intFromBool(s.gliding),
        .sprinting = @intFromBool(s.sprinting),
        .has_gravity = @intFromBool(s.has_gravity),
        .slow_falling = @intFromBool(s.effects.slow_falling),
        .weaving = @intFromBool(s.effects.weaving),
        .depth_strider = s.equipment.depth_strider,
        .soul_speed = s.equipment.soul_speed,
        .swift_sneak = s.equipment.swift_sneak,
        .riptide = s.equipment.riptide,
        .leather_boots = @intFromBool(s.equipment.leather_boots),
        .elytra = @intFromBool(s.equipment.elytra),
        .game_mode = @backingInt(s.game_mode),
        .flying = @intFromBool(s.flying),
        .trust_fly_status = @intFromBool(s.trust_fly_status),
        .no_clip = @intFromBool(s.no_clip),
        .immobile = @intFromBool(s.immobile),
        .ready = @intFromBool(s.ready),
        .alive = @intFromBool(s.alive),
        .in_vehicle = @intFromBool(s.in_vehicle),
        .server_sprint = @intFromBool(s.server_sprint),
        .server_updated_speed = @intFromBool(s.server_updated_speed),
        .riptide_in_rain = @intFromBool(s.riptide_in_rain),
    };
}

export fn rt_state_set(s: *rt.State, v: *const StateView) c_int {
    if (v.game_mode > 3 or v.jump_boost < -1 or v.levitation < -1) return 0;
    var n = s.*;
    n.pos = v.pos;
    n.vel = v.vel;
    n.rotation = .{ .pitch = v.pitch, .head_yaw = v.head_yaw, .yaw = v.yaw };
    n.size = .{
        .width = v.width,
        .height = v.height,
        .scale = v.scale,
        .standing_height = v.standing_height,
        .sneaking_height = v.sneaking_height,
        .crawling_height = v.crawling_height,
    };
    n.movement_speed = v.movement_speed;
    n.default_movement_speed = v.default_movement_speed;
    n.jump_strength = v.jump_strength;
    n.gravity = v.gravity;
    n.underwater_speed = v.underwater_speed;
    n.lava_speed = v.lava_speed;
    n.swim_speed_multiplier = v.swim_speed_multiplier;
    n.fall_distance = v.fall_distance;
    n.effects = .{
        .jump_boost = if (v.jump_boost < 0) null else v.jump_boost,
        .levitation = if (v.levitation < 0) null else v.levitation,
        .slow_falling = v.slow_falling != 0,
        .weaving = v.weaving != 0,
    };
    n.dolphin_boost_ticks = v.dolphin_boost_ticks;
    n.on_ground = v.on_ground != 0;
    n.sneaking = v.sneaking != 0;
    n.crawling = v.crawling != 0;
    n.swimming = v.swimming != 0;
    n.gliding = v.gliding != 0;
    n.sprinting = v.sprinting != 0;
    n.has_gravity = v.has_gravity != 0;
    n.equipment = .{
        .depth_strider = v.depth_strider,
        .soul_speed = v.soul_speed,
        .swift_sneak = v.swift_sneak,
        .riptide = v.riptide,
        .leather_boots = v.leather_boots != 0,
        .elytra = v.elytra != 0,
    };
    n.game_mode = @fromBackingInt(@intCast(v.game_mode));
    n.flying = v.flying != 0;
    n.trust_fly_status = v.trust_fly_status != 0;
    n.no_clip = v.no_clip != 0;
    n.immobile = v.immobile != 0;
    n.ready = v.ready != 0;
    n.alive = v.alive != 0;
    n.in_vehicle = v.in_vehicle != 0;
    n.server_sprint = v.server_sprint != 0;
    n.server_updated_speed = v.server_updated_speed != 0;
    n.riptide_in_rain = v.riptide_in_rain != 0;
    if (!n.isValid()) return 0;
    s.* = n;
    return 1;
}

export fn rt_state_queue_motion(s: *rt.State, vel: Vec3) void {
    s.queueMotion(vel);
}

export fn rt_state_queue_teleport(s: *rt.State, target: Vec3, smoothed_ticks: u32) void {
    s.queueTeleport(target, smoothed_ticks);
}

export fn rt_state_queue_firework_boost(s: *rt.State) void {
    s.queueFireworkBoost();
}

export fn rt_state_set_riptide_ready(s: *rt.State, ready: c_int) void {
    s.riptide_ready = ready != 0;
}

const flag_mask: u32 = (1 << 30) - 1;

export fn rt_tick(cs: *CSimulator, s: *rt.State, in: *const Input, out: *Result) void {
    const input: rt.Input = .{
        .move = .{ .x = in.move_x, .y = in.move_y },
        .move_is_raw = in.move_is_raw != 0,
        .rotation = .{ .pitch = in.pitch, .head_yaw = in.head_yaw, .yaw = in.yaw },
        .reported_pos = in.reported_pos,
        .reported_vel = in.reported_vel,
        .item_use_modifier = if (std.math.isNan(in.item_use_modifier)) null else in.item_use_modifier,
        .flags = @bitCast(in.flags & flag_mask),
    };
    const r = cs.sim.tick(s, &input);
    out.* = .{
        .pos = r.pos,
        .vel = r.vel,
        .mov = r.mov,
        .position_delta = r.position_delta,
        .velocity_delta = r.velocity_delta,
        .mechanics = @bitCast(r.mechanics),
        .outcome = @backingInt(r.outcome),
        .confidence = @backingInt(r.confidence()),
        .on_ground = @intFromBool(r.on_ground),
        .collide_x = @intFromBool(r.collide_x),
        .collide_y = @intFromBool(r.collide_y),
        .collide_z = @intFromBool(r.collide_z),
        .sprint_movement_blocked = @intFromBool(r.sprint_movement_blocked),
    };
}

export fn rt_abi_sizes(out: *[6]u32) void {
    out.* = .{ @sizeOf(Block), @sizeOf(CollisionContext), @sizeOf(Config), @sizeOf(Input), @sizeOf(Result), @sizeOf(StateView) };
}

comptime {
    std.debug.assert(@sizeOf(rt.AABB) == 24);
    std.debug.assert(@bitSizeOf(rt.Input.Flags) == 32);
    std.debug.assert(@as(u32, @bitCast(rt.Input.Flags{ .stop_spin_attack = true })) == 1 << 29);
    std.debug.assert(@as(u32, @bitCast(rt.Input.Flags{ .descend_block = true })) == 1 << 15);
}
