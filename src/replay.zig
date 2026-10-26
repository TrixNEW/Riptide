const std = @import("std");
const state_mod = @import("state.zig");
const liquid = @import("liquid.zig");
const Simulator = @import("Simulator.zig");

const State = state_mod.State;
const Input = state_mod.Input;
const Result = state_mod.Result;

pub const Frame = struct {
    state: State,
    result: Result,
    head: ?liquid.HeadLiquid,
};

pub fn run(sim: *Simulator, initial: State, inputs: []const Input, frames: []Frame) State {
    std.debug.assert(frames.len >= inputs.len);
    var state = initial;
    for (inputs, frames[0..inputs.len]) |*input, *frame| {
        const r = sim.tick(&state, input);
        frame.* = .{ .state = state, .result = r, .head = observeHead(sim, &state) };
    }
    return state;
}

pub fn observeHead(sim: *Simulator, state: *const State) ?liquid.HeadLiquid {
    sim.cache.invalidate();
    return liquid.headLiquid(sim, state) catch null;
}

pub fn firstDivergence(a: []const Result, b: []const Result, tolerance: f32) ?usize {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n], 0..) |x, y, i| {
        if (x.outcome != y.outcome or x.on_ground != y.on_ground) return i;
        if (!close(x.pos, y.pos, tolerance) or !close(x.vel, y.vel, tolerance)) return i;
    }
    return if (a.len != b.len) @min(a.len, b.len) else null;
}

pub fn firstReportedDivergence(results: []const Result, tolerance: f32) ?usize {
    for (results, 0..) |r, i| {
        if (r.outcome == .normal and r.position_delta.len() > tolerance) return i;
    }
    return null;
}

fn close(a: anytype, b: @TypeOf(a), tolerance: f32) bool {
    inline for (.{ "x", "y", "z" }) |f| {
        const d = @abs(@field(a, f) - @field(b, f));
        if (tolerance == 0) {
            if (@as(u32, @bitCast(@field(a, f))) != @as(u32, @bitCast(@field(b, f)))) return false;
        } else if (!(d <= tolerance)) return false;
    }
    return true;
}
