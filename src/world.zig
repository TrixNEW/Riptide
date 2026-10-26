//! The world contract: per-cell block data supplied by the caller.
//!
//! The simulator performs its own broad phase over `World.block`, so
//! collision boxes, support probes, and liquid probes always agree.

const std = @import("std");
const math = @import("math.zig");
const AABB = @import("aabb.zig").AABB;
const Vec3 = math.Vec3;

pub const BlockPos = extern struct {
    x: i32,
    y: i32,
    z: i32,

    pub inline fn init(x: i32, y: i32, z: i32) BlockPos {
        return .{ .x = x, .y = y, .z = z };
    }

    pub inline fn offset(p: BlockPos, dx: i32, dy: i32, dz: i32) BlockPos {
        return .{ .x = p.x +% dx, .y = p.y +% dy, .z = p.z +% dz };
    }

    pub inline fn vec(p: BlockPos) Vec3 {
        return .init(@floatFromInt(p.x), @floatFromInt(p.y), @floatFromInt(p.z));
    }

    pub inline fn eql(a: BlockPos, b: BlockPos) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z;
    }

    /// Vanilla shape gathering order: x, then z, then y ascending.
    pub fn gathersBefore(a: BlockPos, b: BlockPos) bool {
        if (a.x != b.x) return a.x < b.x;
        if (a.z != b.z) return a.z < b.z;
        return a.y < b.y;
    }
};

pub const Bounce = enum(u2) { none, slime, bed };

/// Velocity changes applied while the entity overlaps the block volume.
pub const Inside = enum(u2) { none, sweet_berry_bush, powder_snow };

/// Input-driven vertical traversal supported by a block.
pub const Traversal = enum(u2) { none, scaffolding, powder_snow };

/// Movement behaviour of a block state.
pub const Semantics = struct {
    /// Ground friction (slipperiness). Must be finite and positive.
    friction: f32 = 0.6,
    /// Multiplies friction only when computing ground acceleration.
    accel_friction_mul: f32 = 1,
    /// Soul Speed removes `accel_friction_mul` on this block.
    soul_speed_affected: bool = false,
    climbable: bool = false,
    cobweb: bool = false,
    honey: bool = false,
    /// Carpets defer jump-factor checks to the block below.
    carpet: bool = false,
    bounce: Bounce = .none,
    inside: Inside = .none,
    traversal: Traversal = .none,

    pub const default: Semantics = .{};
    pub const ice: Semantics = .{ .friction = 0.98 };
    pub const blue_ice: Semantics = .{ .friction = 0.989 };
    pub const slime: Semantics = .{ .friction = 0.8, .bounce = .slime };
    pub const honey_block: Semantics = .{ .friction = 0.8, .honey = true };
    pub const bed: Semantics = .{ .bounce = .bed };
    /// Native acceleration adjustment used on soul sand.
    pub const soul_sand: Semantics = .{ .accel_friction_mul = 1.225000023841858, .soul_speed_affected = true };
    pub const ladder: Semantics = .{ .climbable = true };
    pub const cobweb_block: Semantics = .{ .cobweb = true };
    pub const sweet_berry_bush: Semantics = .{ .inside = .sweet_berry_bush };
    pub const powder_snow: Semantics = .{ .inside = .powder_snow, .traversal = .powder_snow };
    pub const scaffolding: Semantics = .{ .traversal = .scaffolding };
    pub const carpet_block: Semantics = .{ .carpet = true };

    pub fn isValid(s: Semantics) bool {
        return validFactor(s.friction) and validFactor(s.accel_friction_mul);
    }

    fn validFactor(v: f32) bool {
        return v > 0 and v < std.math.inf(f32);
    }

    /// Built-in semantics for a vanilla block identifier such as
    /// `minecraft:blue_ice`. Unknown names get the default semantics.
    pub fn fromName(name: []const u8) Semantics {
        if (by_name.get(name)) |s| return s;
        if (std.mem.endsWith(u8, name, "_carpet")) return carpet_block;
        return .{};
    }

    const by_name: std.StaticStringMap(Semantics) = .initComptime(.{
        .{ "minecraft:ice", ice },
        .{ "minecraft:frosted_ice", ice },
        .{ "minecraft:packed_ice", ice },
        .{ "minecraft:blue_ice", blue_ice },
        .{ "minecraft:slime", slime },
        .{ "minecraft:honey_block", honey_block },
        .{ "minecraft:bed", bed },
        .{ "minecraft:soul_sand", soul_sand },
        .{ "minecraft:ladder", ladder },
        .{ "minecraft:vine", ladder },
        .{ "minecraft:cave_vines", ladder },
        .{ "minecraft:cave_vines_body_with_berries", ladder },
        .{ "minecraft:cave_vines_head_with_berries", ladder },
        .{ "minecraft:twisting_vines", ladder },
        .{ "minecraft:weeping_vines", ladder },
        .{ "minecraft:web", cobweb_block },
        .{ "minecraft:sweet_berry_bush", sweet_berry_bush },
        .{ "minecraft:powder_snow", powder_snow },
        .{ "minecraft:scaffolding", scaffolding },
        .{ "minecraft:carpet", carpet_block },
        .{ "minecraft:moss_carpet", carpet_block },
    });
};

pub const LiquidKind = enum(u1) { water, lava };

pub const Liquid = packed struct(u8) {
    kind: LiquidKind,
    /// Bedrock `liquid_depth` decay: 0 is a source, 1..7 flow outwards.
    level: u3 = 0,
    falling: bool = false,
    _pad: u3 = 0,

    pub const water_source: Liquid = .{ .kind = .water };
    pub const lava_source: Liquid = .{ .kind = .lava };

    /// Surface height inside the cell.
    pub inline fn height(l: Liquid) f32 {
        if (l.falling) return 1;
        const depth: f32 = @floatFromInt(9 - @as(u8, l.level));
        return depth / 9;
    }

    /// Decay used for flow gradients. Falling liquid counts as a source.
    pub inline fn decay(l: Liquid) i32 {
        return if (l.falling) 0 else l.level;
    }
};

/// Horizontal faces, used for liquid flow closure.
pub const Faces = packed struct(u4) {
    west: bool = false,
    east: bool = false,
    north: bool = false,
    south: bool = false,

    pub const all: Faces = .{ .west = true, .east = true, .north = true, .south = true };
};

pub const BubbleColumn = enum(u2) { none, up, down };

/// What occupies the primary block layer.
pub const Kind = enum(u2) {
    air,
    /// A pure liquid block. `Block.liquid` describes it.
    liquid,
    /// Any other block, possibly waterlogged through `Block.liquid`.
    block,
};

/// Movement-relevant data for one block cell, merged across both layers.
pub const Block = struct {
    kind: Kind = .block,
    /// Collision boxes in block-local space, gathered in this order. They
    /// must lie within [0, 1] horizontally and [0, 1.5] vertically, and stay
    /// valid and unchanged for the duration of the simulation call.
    shape: []const AABB = &.{},
    semantics: Semantics = .{},
    /// Primary or second-layer (waterlogging) liquid.
    liquid: ?Liquid = null,
    /// Faces that close horizontal liquid flow.
    solid_faces: Faces = .{},
    /// Bends falling liquid flow downward. Usually true for colliding blocks.
    flow_barrier: bool = false,
    bubble: BubbleColumn = .none,
    /// Exact bubble-column surface variant, if known. Null falls back to
    /// checking for air above.
    bubble_surface: ?bool = null,
    /// The shape depends on the player and must be resolved through
    /// `World.VTable.dynamic_shape`.
    dynamic_shape: bool = false,

    pub const air: Block = .{ .kind = .air };

    /// A full solid cube with the given semantics.
    pub fn full(semantics: Semantics) Block {
        return .{
            .shape = &unit_shape,
            .semantics = semantics,
            .solid_faces = .all,
            .flow_barrier = true,
        };
    }

    pub fn liquidBlock(liquid: Liquid) Block {
        return .{ .kind = .liquid, .liquid = liquid };
    }

    pub inline fn isAir(b: Block) bool {
        return b.kind == .air;
    }
};

const unit_shape = [_]AABB{AABB.unit};

/// Player-dependent collision inputs for scaffolding and powder snow.
pub const CollisionContext = struct {
    position: Vec3,
    sneaking: bool,
    descending: bool,
    want_down: bool,
    leather_boots: bool,
    /// Set while the player sinks through scaffolding or powder snow.
    /// Vanilla drops those blocks' top collision only in this state.
    descend_through_block: bool,
};

/// Output buffer for dynamic shapes.
pub const ShapeBuffer = struct {
    boxes: [max_dynamic_boxes]AABB = undefined,
    len: u8 = 0,

    pub const max_dynamic_boxes = 8;

    pub fn append(s: *ShapeBuffer, box: AABB) void {
        if (s.len < max_dynamic_boxes) {
            s.boxes[s.len] = box;
            s.len += 1;
        }
    }

    pub fn slice(s: *const ShapeBuffer) []const AABB {
        return s.boxes[0..s.len];
    }
};

/// Read-only world snapshot. Every call within one simulation call must
/// observe the same world state. Implementations need not be thread-safe
/// unless shared between threads.
pub const World = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Block data at `pos`, or null if the cell is not loaded or unknown.
        block: *const fn (ptr: *anyopaque, pos: BlockPos) ?Block,
        /// Collision boxes of a block with `dynamic_shape` set, in
        /// block-local space. Null treats such blocks as having their static
        /// `shape`.
        dynamic_shape: ?*const fn (ptr: *anyopaque, pos: BlockPos, block: *const Block, ctx: *const CollisionContext, out: *ShapeBuffer) void = null,
    };

    pub inline fn block(w: World, pos: BlockPos) ?Block {
        return w.vtable.block(w.ptr, pos);
    }
};

/// A sparse hash-map world. Cells outside `loaded` are unknown; loaded cells
/// default to air. Intended for tests, tools, and prototyping.
pub const MapWorld = struct {
    blocks: std.AutoHashMapUnmanaged(BlockPos, Block) = .empty,
    /// Inclusive bounds of loaded cells.
    loaded_min: BlockPos = .init(std.math.minInt(i32), std.math.minInt(i32), std.math.minInt(i32)),
    loaded_max: BlockPos = .init(std.math.maxInt(i32), std.math.maxInt(i32), std.math.maxInt(i32)),

    pub fn deinit(w: *MapWorld, gpa: std.mem.Allocator) void {
        w.blocks.deinit(gpa);
        w.* = undefined;
    }

    pub fn put(w: *MapWorld, gpa: std.mem.Allocator, pos: BlockPos, b: Block) !void {
        try w.blocks.put(gpa, pos, b);
    }

    /// Fills an inclusive box of cells.
    pub fn fill(w: *MapWorld, gpa: std.mem.Allocator, from: BlockPos, to: BlockPos, b: Block) !void {
        var x = from.x;
        while (x <= to.x) : (x += 1) {
            var y = from.y;
            while (y <= to.y) : (y += 1) {
                var z = from.z;
                while (z <= to.z) : (z += 1) try w.put(gpa, .init(x, y, z), b);
            }
        }
    }

    pub fn world(w: *MapWorld) World {
        return .{ .ptr = w, .vtable = &vtable };
    }

    const vtable: World.VTable = .{ .block = lookup };

    fn lookup(ptr: *anyopaque, pos: BlockPos) ?Block {
        const w: *MapWorld = @ptrCast(@alignCast(ptr));
        if (pos.x < w.loaded_min.x or pos.y < w.loaded_min.y or pos.z < w.loaded_min.z or
            pos.x > w.loaded_max.x or pos.y > w.loaded_max.y or pos.z > w.loaded_max.z) return null;
        return w.blocks.get(pos) orelse .air;
    }
};

test "liquid heights" {
    try std.testing.expectEqual(@as(f32, 1), Liquid.water_source.height());
    try std.testing.expectEqual(@as(f32, 8.0 / 9.0), (Liquid{ .kind = .water, .level = 1 }).height());
    try std.testing.expectEqual(@as(f32, 1), (Liquid{ .kind = .water, .level = 7, .falling = true }).height());
    try std.testing.expectEqual(@as(i32, 0), (Liquid{ .kind = .water, .level = 3, .falling = true }).decay());
}

test "semantics by name" {
    try std.testing.expectEqual(@as(f32, 0.989), Semantics.fromName("minecraft:blue_ice").friction);
    try std.testing.expect(Semantics.fromName("minecraft:red_carpet").carpet);
    try std.testing.expect(Semantics.fromName("minecraft:twisting_vines").climbable);
    try std.testing.expectEqual(@as(f32, 0.6), Semantics.fromName("minecraft:stone").friction);
    try std.testing.expect(Semantics.fromName("minecraft:soul_sand").soul_speed_affected);
}

test "map world reports unloaded cells" {
    var w: MapWorld = .{ .loaded_min = .init(-16, -64, -16), .loaded_max = .init(15, 319, 15) };
    defer w.deinit(std.testing.allocator);
    try w.put(std.testing.allocator, .init(0, 0, 0), .full(.ice));
    const view = w.world();
    try std.testing.expect(view.block(.init(16, 0, 0)) == null);
    try std.testing.expect(view.block(.init(1, 0, 0)).?.isAir());
    try std.testing.expectEqual(@as(f32, 0.98), view.block(.init(0, 0, 0)).?.semantics.friction);
}
