const std = @import("std");
const rt = @import("riptide");

pub const Sem = struct {
    friction: f32,
    accel_mul: f32,
    soul_speed: bool = false,
    climbable: bool = false,
    cobweb: bool = false,
    honey: bool = false,
    carpet: bool = false,
    bounce: []const u8 = "",
    inside: []const u8 = "",
    traversal: []const u8 = "",
};

pub const LiquidSpec = struct { kind: []const u8, level: u3, falling: bool = false };

pub const BlockSpec = struct {
    kind: []const u8,
    boxes: []const [6]f32 = &.{},
    sem: Sem,
    liquid: ?LiquidSpec = null,
    solid_faces: u4 = 0,
    barrier: bool = false,
    bubble: []const u8 = "",
    bubble_surface: ?bool = null,
    dynamic: []const u8 = "",
};

pub const Fill = struct { from: [3]i32, to: [3]i32, block: BlockSpec };

pub const StateSpec = struct {
    pos: [3]f32,
    vel: [3]f32,
    yaw: f32,
    pitch: f32,
    on_ground: bool = false,
    sneaking: bool = false,
    crawling: bool = false,
    swimming: bool = false,
    gliding: bool = false,
    sprinting: bool = false,
    height: f32,
    speed: f32,
    default_speed: f32,
    gravity: f32,
    no_gravity: bool = false,
    fall_distance: f32,
    glide_boost: u8 = 0,
    swim_multiplier: f32,
    dolphin_ticks: u32 = 0,
    jump_boost: ?i32 = null,
    levitation: ?i32 = null,
    slow_falling: bool = false,
    weaving: bool = false,
    depth_strider: u8 = 0,
    soul_speed: u8 = 0,
    swift_sneak: u8 = 0,
    riptide: u8 = 0,
    leather_boots: bool = false,
    elytra: bool = false,
    riptide_in_rain: bool = false,
};

pub const InputSpec = struct {
    move: [2]f32,
    raw: bool = false,
    yaw: f32,
    pitch: f32,
    item_use: ?f32 = null,
    flags: []const []const u8 = &.{},
    motion: ?[3]f32 = null,
    teleport: ?struct { pos: [3]f32, smoothed: u32 } = null,
    riptide_ready: bool = false,
};

pub const Expect = struct {
    outcome: []const u8 = "normal",
    pos: [3]f32,
    vel: [3]f32,
    mov: [3]f32,
    on_ground: bool = false,
    collide: u3 = 0,
    fall: f32 = 0,
    height: f32,
    sneaking: bool = false,
    crawling: bool = false,
    swimming: bool = false,
    gliding: bool = false,
    jump_delay: u8 = 0,
    riptide: u8 = 0,
};

pub const Scenario = struct {
    name: []const u8,
    evidence: []const u8,
    sprint_legacy: bool = false,
    world: []const Fill,
    state: StateSpec,
    inputs: []const InputSpec,
    expected: []const Expect,
};

fn enumOf(comptime E: type, s: []const u8) !E {
    if (s.len == 0) return @fromBackingInt(@intCast(0));
    return std.meta.stringToEnum(E, s) orelse error.BadFixture;
}

fn vec(v: [3]f32) rt.Vec3 {
    return .init(v[0], v[1], v[2]);
}

pub fn buildWorld(arena: std.mem.Allocator, fills: []const Fill) !rt.MapWorld {
    var w: rt.MapWorld = .{};
    for (fills) |f| {
        const spec = f.block;
        const boxes = try arena.alloc(rt.AABB, spec.boxes.len);
        for (spec.boxes, boxes) |b, *o| o.* = .init(b[0], b[1], b[2], b[3], b[4], b[5]);
        const s = spec.sem;
        const kind = try enumOf(@FieldType(rt.Block, "kind"), spec.kind);
        const faces: rt.Faces = @bitCast(spec.solid_faces);
        const b: rt.Block = .{
            .kind = kind,
            .shape = boxes,
            .semantics = .{
                .friction = s.friction,
                .accel_friction_mul = s.accel_mul,
                .soul_speed_affected = s.soul_speed,
                .climbable = s.climbable,
                .cobweb = s.cobweb,
                .honey = s.honey,
                .carpet = s.carpet,
                .bounce = try enumOf(@FieldType(rt.Semantics, "bounce"), s.bounce),
                .inside = try enumOf(@FieldType(rt.Semantics, "inside"), s.inside),
                .traversal = try enumOf(@FieldType(rt.Semantics, "traversal"), s.traversal),
            },
            .liquid = if (spec.liquid) |l| .{ .kind = try enumOf(rt.LiquidKind, l.kind), .level = l.level, .falling = l.falling } else null,
            .solid_faces = faces,
            .flow_barrier = spec.barrier,
            .bubble = try enumOf(rt.BubbleColumn, spec.bubble),
            .bubble_surface = spec.bubble_surface,
            .dynamic_shape = spec.dynamic.len != 0,
        };
        try w.fill(arena, .init(f.from[0], f.from[1], f.from[2]), .init(f.to[0], f.to[1], f.to[2]), b);
    }
    return w;
}

pub fn initialState(s: StateSpec) rt.State {
    const rot: rt.Rotation = .{ .pitch = s.pitch, .head_yaw = s.yaw, .yaw = s.yaw };
    var st: rt.State = .{
        .pos = vec(s.pos),
        .vel = vec(s.vel),
        .rotation = rot,
        .last_rotation = rot,
        .on_ground = s.on_ground,
        .sneaking = s.sneaking,
        .crawling = s.crawling,
        .swimming = s.swimming,
        .gliding = s.gliding,
        .sprinting = s.sprinting,
        .movement_speed = s.speed,
        .default_movement_speed = s.default_speed,
        .gravity = s.gravity,
        .has_gravity = !s.no_gravity,
        .fall_distance = s.fall_distance,
        .glide_boost_ticks = s.glide_boost,
        .swim_speed_multiplier = s.swim_multiplier,
        .dolphin_boost_ticks = s.dolphin_ticks,
        .riptide_in_rain = s.riptide_in_rain,
        .effects = .{ .jump_boost = s.jump_boost, .levitation = s.levitation, .slow_falling = s.slow_falling, .weaving = s.weaving },
        .equipment = .{
            .depth_strider = s.depth_strider,
            .soul_speed = s.soul_speed,
            .swift_sneak = s.swift_sneak,
            .riptide = s.riptide,
            .leather_boots = s.leather_boots,
            .elytra = s.elytra,
        },
    };
    st.size.height = s.height;
    if (s.sprinting) st.air_speed = 0.026;
    return st;
}

pub fn input(spec: InputSpec) !rt.Input {
    var in: rt.Input = .{
        .move = .{ .x = spec.move[0], .y = spec.move[1] },
        .move_is_raw = spec.raw,
        .rotation = .{ .pitch = spec.pitch, .head_yaw = spec.yaw, .yaw = spec.yaw },
        .item_use_modifier = spec.item_use,
    };
    for (spec.flags) |name| {
        var found = false;
        const info = @typeInfo(rt.Input.Flags).@"struct";
        inline for (info.field_names, info.field_types) |fname, ftype| {
            if (ftype == bool and std.mem.eql(u8, fname, name)) {
                @field(in.flags, fname) = true;
                found = true;
            }
        }
        if (!found) return error.BadFixture;
    }
    return in;
}

fn bitsEq(a: f32, b: f32) bool {
    return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
}

fn vecEq(a: rt.Vec3, b: [3]f32) bool {
    return bitsEq(a.x, b[0]) and bitsEq(a.y, b[1]) and bitsEq(a.z, b[2]);
}

pub fn compare(r: rt.Result, s: *const rt.State, e: Expect) ?[]const u8 {
    if (!std.mem.eql(u8, @tagName(r.outcome), e.outcome)) return "outcome";
    if (!vecEq(s.pos, e.pos)) return "pos";
    if (!vecEq(s.vel, e.vel)) return "vel";
    if (!vecEq(s.mov, e.mov)) return "mov";
    if (s.on_ground != e.on_ground) return "on_ground";
    const collide = @as(u3, @intFromBool(s.collide_x)) | @as(u3, @intFromBool(s.collide_y)) << 1 | @as(u3, @intFromBool(s.collide_z)) << 2;
    if (collide != e.collide) return "collide";
    if (!bitsEq(s.fall_distance, e.fall)) return "fall_distance";
    if (!bitsEq(s.size.height, e.height)) return "height";
    if (s.sneaking != e.sneaking or s.crawling != e.crawling or s.swimming != e.swimming or s.gliding != e.gliding) return "pose";
    if (s.jump_delay != e.jump_delay) return "jump_delay";
    if (s.riptide_ticks != e.riptide) return "riptide_ticks";
    return null;
}

pub const mechanic_names = @typeInfo(rt.Mechanics).@"struct".field_names;
pub var coverage: [mechanic_names.len]u32 = @splat(0);

pub fn countMechanics(m: rt.Mechanics) void {
    inline for (mechanic_names, 0..) |name, i| {
        if (@TypeOf(@field(m, name)) == bool and @field(m, name)) coverage[i] += 1;
    }
}

const dynamic_vtable: rt.World.VTable = .{ .block = mapLookup, .dynamic_shape = scaffoldShape };

fn mapLookup(ptr: *anyopaque, pos: rt.BlockPos) ?rt.Block {
    const w: *rt.MapWorld = @ptrCast(@alignCast(ptr));
    return w.world().block(pos);
}

fn scaffoldShape(_: *anyopaque, pos: rt.BlockPos, _: *const rt.Block, ctx: *const rt.CollisionContext, out: *rt.ShapeBuffer) void {
    if (!ctx.descend_through_block and ctx.position.y >= @as(f32, @floatFromInt(pos.y + 1)) - 1e-5) {
        out.append(.init(0, 0.875, 0, 1, 1, 1));
    }
}

pub const Prepared = struct {
    world: rt.MapWorld,
    initial: rt.State,
    steps: []const Step,
    legacy: bool,

    pub const Step = struct {
        input: rt.Input,
        motion: ?rt.Vec3,
        teleport: ?struct { pos: rt.Vec3, smoothed: u32 },
        riptide_ready: bool,
    };

    pub fn simulator(p: *Prepared) rt.Simulator {
        return .init(.{ .ptr = &p.world, .vtable = &dynamic_vtable }, .{ .policy = .hardened, .sprint_timing = if (p.legacy) .legacy else .modern });
    }

    pub fn tick(sim: *rt.Simulator, state: *rt.State, step: *const Step) rt.Result {
        if (step.motion) |m| state.queueMotion(m);
        if (step.teleport) |t| state.queueTeleport(t.pos, t.smoothed);
        state.riptide_ready = step.riptide_ready;
        return sim.tick(state, &step.input);
    }
};

pub fn prepare(sc: *const Scenario, arena: std.mem.Allocator) !Prepared {
    const steps = try arena.alloc(Prepared.Step, sc.inputs.len);
    for (sc.inputs, steps) |spec, *st| st.* = .{
        .input = try input(spec),
        .motion = if (spec.motion) |m| vec(m) else null,
        .teleport = if (spec.teleport) |t| .{ .pos = vec(t.pos), .smoothed = t.smoothed } else null,
        .riptide_ready = spec.riptide_ready,
    };
    return .{ .world = try buildWorld(arena, sc.world), .initial = initialState(sc.state), .steps = steps, .legacy = sc.sprint_legacy };
}

pub fn runScenario(sc: *const Scenario, arena: std.mem.Allocator, verbose: bool) !bool {
    var p = try prepare(sc, arena);
    var sim = p.simulator();
    var state = p.initial;
    for (p.steps, sc.expected, 0..) |*step, e, tick| {
        const r = Prepared.tick(&sim, &state, step);
        if (verbose) countMechanics(r.mechanics);
        if (compare(r, &state, e)) |field| {
            if (verbose) {
                std.debug.print("{s}: tick {d} diverges on {s}\n  got  pos={f} vel={f} mov={f} ground={} outcome={t}\n  want pos={any} vel={any} mov={any} ground={} outcome={s}\n", .{
                    sc.name,   tick,  field, state.pos, state.vel,   state.mov, state.on_ground,
                    r.outcome, e.pos, e.vel, e.mov,     e.on_ground, e.outcome,
                });
            }
            return false;
        }
    }
    return true;
}
