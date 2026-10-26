//! Riptide: a deterministic Minecraft Bedrock player movement simulator.
//!
//! ```zig
//! var sim = riptide.Simulator.init(my_world, .{ .policy = .hardened });
//! var state: riptide.State = .{ .pos = spawn };
//! const result = sim.tick(&state, &input);
//! ```

const math = @import("math.zig");
const aabb = @import("aabb.zig");
const world = @import("world.zig");
const state = @import("state.zig");
const trace = @import("trace.zig");

pub const version = "0.1.0";

pub const Vec3 = math.Vec3;
pub const Vec2 = math.Vec2;
pub const AABB = aabb.AABB;

pub const World = world.World;
pub const Block = world.Block;
pub const BlockPos = world.BlockPos;
pub const Semantics = world.Semantics;
pub const Liquid = world.Liquid;
pub const LiquidKind = world.LiquidKind;
pub const Faces = world.Faces;
pub const BubbleColumn = world.BubbleColumn;
pub const CollisionContext = world.CollisionContext;
pub const ShapeBuffer = world.ShapeBuffer;
pub const MapWorld = world.MapWorld;

pub const State = state.State;
pub const Input = state.Input;
pub const Rotation = state.Rotation;
pub const Effects = state.Effects;
pub const Equipment = state.Equipment;
pub const Size = state.Size;
pub const GameMode = state.GameMode;
pub const Config = state.Config;
pub const Policy = state.Policy;
pub const SwimGrace = state.SwimGrace;
pub const SprintTiming = state.SprintTiming;
pub const Result = state.Result;
pub const Outcome = state.Outcome;
pub const Mechanics = state.Mechanics;
pub const Confidence = state.Confidence;
pub const Correction = state.Correction;

pub const Simulator = @import("Simulator.zig");
pub const Trace = trace.Trace;
pub const TraceEvent = trace.Event;
pub const replay = @import("replay.zig");
pub const HeadLiquid = @import("liquid.zig").HeadLiquid;

/// Bedrock trigonometry and float32 helpers.
pub const mc = struct {
    pub const sin = math.mcSin;
    pub const cos = math.mcCos;
    pub const jumpImpulse = Simulator.jumpImpulse;
    pub const sprintMovementBlocked = Simulator.sprintMovementBlocked;
};

test {
    _ = math;
    _ = aabb;
    _ = world;
    _ = state;
    _ = trace;
    _ = Simulator;
    _ = replay;
}
