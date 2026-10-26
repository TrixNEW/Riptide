//! Simulates a player sprint-jumping across a stone floor onto a slab and
//! compares the result with client reports.

const std = @import("std");
const rt = @import("riptide");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    const w = &out.interface;

    // A world adapter would normally wrap the server's chunk storage.
    var map: rt.MapWorld = .{};
    defer map.deinit(gpa);
    try map.fill(gpa, .init(-16, -1, -16), .init(16, -1, 16), .full(.default));
    const slab = [_]rt.AABB{.init(0, 0, 0, 1, 0.5, 1)};
    try map.fill(gpa, .init(-2, 0, 6), .init(2, 0, 6), .{ .shape = &slab });

    var sim: rt.Simulator = .init(map.world(), .{ .policy = .hardened });
    var state: rt.State = .{ .pos = .init(0.5, 0, 0.5), .on_ground = true };
    // Stand-in for the remote client: an honest one runs the same physics.
    var client = state;
    const correction: rt.Correction = .{ .position_threshold = 0.03, .velocity_threshold = 0 };

    for (0..20) |tick| {
        var input: rt.Input = .{ .move = .{ .y = 1 }, .flags = .{ .sprint_down = true } };
        input.flags.start_sprinting = tick == 0;
        input.flags.start_jumping = tick == 3;
        input.flags.jumping = tick == 3;

        _ = sim.tick(&client, &input);
        input.reported_pos = client.pos;
        // On tick 10 the client claims to be half a block further ahead.
        if (tick == 10) input.reported_pos.z += 0.5;

        const r = sim.tick(&state, &input);
        try w.print("tick {d:>2} {t:<8} pos={f} ground={} step={} confidence={t} correct={}\n", .{
            tick, r.outcome, r.pos, r.on_ground, r.mechanics.step, r.confidence(), correction.needed(r),
        });
    }
    try w.flush();
}
