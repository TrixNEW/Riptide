//! Differential fixtures: every compared value must match BedSim bit for bit.

const std = @import("std");
const fixture = @import("fixture.zig");

test "bedsim differential fixtures" {
    const data = @embedFile("fixtures/bedsim.json");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const scenarios = try std.json.parseFromSliceLeaky([]fixture.Scenario, arena_state.allocator(), data, .{});
    var failed: usize = 0;
    for (scenarios) |*sc| {
        var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer scratch.deinit();
        if (!try fixture.runScenario(sc, scratch.allocator(), true)) failed += 1;
    }
    // Every mechanic the fixtures claim to cover must actually occur.
    inline for (fixture.mechanic_names, 0..) |name, i| {
        const optional = comptime std.mem.eql(u8, name, "_pad") or std.mem.eql(u8, name, "dynamic_shape") or
            std.mem.eql(u8, name, "glide_boost") or std.mem.eql(u8, name, "swim_grace");
        if (!optional and fixture.coverage[i] == 0) {
            std.debug.print("mechanic {s} never exercised by fixtures\n", .{name});
            failed += 1;
        }
    }
    if (failed != 0) {
        std.debug.print("{d}/{d} fixtures diverged\n", .{ failed, scenarios.len });
        return error.FixtureDivergence;
    }
}
