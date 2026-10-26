//! Benchmarks. Run with `zig build bench -Doptimize=ReleaseFast`.
//!
//! Workloads run on a dense chunk-like grid world. `fixtures` replays the
//! differential fixtures on the hash-map world, matching tools/oracle's Go
//! benchmark workload for a like-for-like comparison.

const std = @import("std");
const rt = @import("riptide");
const fixture = @import("fixture");

const Io = std.Io;

/// Dense palette-indexed block storage, similar to a loaded chunk section.
const GridWorld = struct {
    const sx = 96;
    const sy = 48;
    const sz = 96;
    const ox = -48;
    const oy = -8;
    const oz = -48;

    cells: [sx * sy * sz]u8 = @splat(0),
    palette: [32]rt.Block = @splat(.air),
    palette_len: u8 = 1,
    lookups: u64 = 0,

    fn add(g: *GridWorld, b: rt.Block) u8 {
        g.palette[g.palette_len] = b;
        g.palette_len += 1;
        return g.palette_len - 1;
    }

    fn set(g: *GridWorld, x: i32, y: i32, z: i32, id: u8) void {
        g.cells[index(x, y, z).?] = id;
    }

    fn fill(g: *GridWorld, x0: i32, y0: i32, z0: i32, x1: i32, y1: i32, z1: i32, id: u8) void {
        var x = x0;
        while (x <= x1) : (x += 1) {
            var y = y0;
            while (y <= y1) : (y += 1) {
                var z = z0;
                while (z <= z1) : (z += 1) g.set(x, y, z, id);
            }
        }
    }

    inline fn index(x: i32, y: i32, z: i32) ?usize {
        const ux = x -% ox;
        const uy = y -% oy;
        const uz = z -% oz;
        if (ux < 0 or ux >= sx or uy < 0 or uy >= sy or uz < 0 or uz >= sz) return null;
        return (@as(usize, @intCast(uy)) * sz + @as(usize, @intCast(uz))) * sx + @as(usize, @intCast(ux));
    }

    fn world(g: *GridWorld) rt.World {
        return .{ .ptr = g, .vtable = &.{ .block = lookup } };
    }

    fn lookup(ptr: *anyopaque, pos: rt.BlockPos) ?rt.Block {
        const g: *GridWorld = @ptrCast(@alignCast(ptr));
        g.lookups += 1;
        const i = index(pos.x, pos.y, pos.z) orelse return null;
        return g.palette[g.cells[i]];
    }
};

const slab = [_]rt.AABB{.init(0, 0, 0, 1, 0.5, 1)};
const stairs = [_]rt.AABB{ .init(0, 0, 0, 1, 0.5, 1), .init(0, 0.5, 0.5, 1, 1, 1) };
const fence = [_]rt.AABB{.init(0.375, 0, 0.375, 0.625, 1.5, 0.625)};
const ladder = [_]rt.AABB{.init(0, 0, 0.8125, 1, 1, 1)};
const scaffold = [_]rt.AABB{.init(0, 0.875, 0, 1, 1, 1)};
const lattice = [_]rt.AABB{
    .init(0, 0, 0, 0.25, 1, 0.25), .init(0.75, 0, 0, 1, 1, 0.25),
    .init(0, 0, 0.75, 0.25, 1, 1), .init(0.75, 0, 0.75, 1, 1, 1),
    .init(0, 0.9, 0, 1, 1, 1),     .init(0.4, 0, 0.4, 0.6, 0.6, 0.6),
};

const Workload = enum { flat, complex, water, lava, climb_special, glide, dense };

const Rng = std.Random.DefaultPrng;

fn buildWorld(g: *GridWorld, w: Workload, rng: std.Random) void {
    const stone = g.add(.full(.default));
    g.fill(-48, -1, -48, 47, -1, 47, stone);
    switch (w) {
        .flat, .glide => {},
        .complex => {
            const ids = [_]u8{ stone, g.add(.{ .shape = &slab }), g.add(.{ .shape = &stairs }), g.add(.{ .shape = &fence }), g.add(.full(.ice)) };
            for (0..900) |_| {
                const x = rng.intRangeLessThan(i32, -40, 40);
                const z = rng.intRangeLessThan(i32, -40, 40);
                g.set(x, rng.intRangeLessThan(i32, 0, 2), z, ids[rng.uintLessThan(usize, ids.len)]);
            }
        },
        .water => g.fill(-40, 0, -40, 39, 6, 39, g.add(.liquidBlock(.water_source))),
        .lava => g.fill(-40, 0, -40, 39, 1, 39, g.add(.liquidBlock(.lava_source))),
        .climb_special => {
            const ids = [_]u8{
                g.add(.{ .shape = &ladder, .semantics = .ladder }),
                g.add(.{ .shape = &scaffold, .semantics = .scaffolding }),
                g.add(.{ .semantics = .cobweb_block }),
                g.add(.{ .semantics = .sweet_berry_bush }),
                g.add(.{ .semantics = .powder_snow }),
                g.add(.full(.honey_block)),
                g.add(.full(.slime)),
            };
            for (0..1500) |_| {
                const x = rng.intRangeLessThan(i32, -40, 40);
                const z = rng.intRangeLessThan(i32, -40, 40);
                g.set(x, rng.intRangeLessThan(i32, 0, 3), z, ids[rng.uintLessThan(usize, ids.len)]);
            }
        },
        .dense => g.fill(-40, 0, -40, 39, 3, 39, g.add(.{ .shape = &lattice })),
    }
}

fn spawnState(w: Workload, rng: std.Random) rt.State {
    const x = rng.float(f32) * 40 - 20;
    const z = rng.float(f32) * 40 - 20;
    var s: rt.State = .{ .pos = .init(x, 0, z), .on_ground = true };
    switch (w) {
        .water => {
            s.pos.y = 1;
            s.on_ground = false;
            s.swimming = true;
        },
        .glide => {
            s.pos.y = 36;
            s.on_ground = false;
            s.gliding = true;
            s.equipment.elytra = true;
            s.vel = .init(0, -0.2, 0.8);
        },
        .dense => s.pos.y = 4,
        else => {},
    }
    return s;
}

/// Players turn steadily so they circle within the loaded area.
fn nextInput(w: Workload, rng: std.Random, tick: u32, in: *rt.Input) void {
    in.rotation.yaw += 4 + rng.float(f32) * 4;
    in.rotation.pitch = std.math.clamp(in.rotation.pitch + rng.float(f32) * 6 - 3, -60, 60);
    in.move = .{ .y = 1, .x = if (rng.uintLessThan(u8, 8) == 0) rng.float(f32) * 2 - 1 else 0 };
    in.flags = .{ .sprint_down = true, .start_sprinting = tick == 0 };
    switch (w) {
        .glide => {
            in.move = .{};
        },
        .water => in.flags.jumping = rng.uintLessThan(u8, 4) == 0,
        else => {
            const jump = rng.uintLessThan(u8, 10) == 0;
            in.flags.start_jumping = jump;
            in.flags.jumping = jump or rng.uintLessThan(u8, 6) == 0;
            in.flags.sneak_down = rng.uintLessThan(u8, 20) == 0;
        },
    }
}

const players = 64;
const ticks_per_player = 1500;
const runs = 5;

fn now(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn median(xs: []f64) f64 {
    std.mem.sort(f64, xs, {}, std.sort.asc(f64));
    return xs[xs.len / 2];
}

fn benchWorkload(io: Io, w: Workload, out: *Io.Writer) !void {
    const g = try std.heap.page_allocator.create(GridWorld);
    defer std.heap.page_allocator.destroy(g);
    g.* = .{};
    var prng: Rng = .init(@backingInt(w) + 1);
    buildWorld(g, w, prng.random());

    var sim: rt.Simulator = .init(g.world(), .{ .policy = .hardened });
    var samples: [runs]f64 = undefined;
    var normal: u64 = 0;
    var lookups: u64 = 0;
    for (&samples) |*sample| {
        var states: [players]rt.State = undefined;
        var inputs: [players]rt.Input = @splat(.{});
        for (&states) |*s| s.* = spawnState(w, prng.random());
        // Inputs are generated outside the timed region.
        const script = try std.heap.page_allocator.alloc(rt.Input, players * ticks_per_player);
        defer std.heap.page_allocator.free(script);
        for (0..ticks_per_player) |t| for (0..players) |p| {
            nextInput(w, prng.random(), @intCast(t), &inputs[p]);
            script[t * players + p] = inputs[p];
        };
        g.lookups = 0;
        normal = 0;
        const start = now(io);
        for (0..ticks_per_player) |t| for (&states, 0..) |*s, p| {
            if (w == .glide and t % 80 == 0) s.queueFireworkBoost();
            const r = sim.tick(s, &script[t * players + p]);
            normal += @intFromBool(r.outcome == .normal);
        };
        const elapsed: f64 = @floatFromInt(now(io) - start);
        sample.* = elapsed / (players * ticks_per_player);
        lookups = g.lookups;
    }
    const total: f64 = players * ticks_per_player;
    const ns = median(&samples);
    try out.print("{s:<16} {d:>8.1} ns/tick {d:>10.2} Mticks/s {d:>7.1} lookups/tick {d:>5.1}% simulated\n", .{
        @tagName(w), ns, 1e3 / ns, @as(f64, @floatFromInt(lookups)) / total, @as(f64, @floatFromInt(normal)) * 100 / total,
    });
}

fn benchReplay(io: Io, out: *Io.Writer) !void {
    const g = try std.heap.page_allocator.create(GridWorld);
    defer std.heap.page_allocator.destroy(g);
    g.* = .{};
    var prng: Rng = .init(99);
    buildWorld(g, .complex, prng.random());
    var sim: rt.Simulator = .init(g.world(), .{ .policy = .hardened });
    var inputs: [200]rt.Input = undefined;
    var in: rt.Input = .{};
    for (&inputs, 0..) |*i, t| {
        nextInput(.complex, prng.random(), @intCast(t), &in);
        i.* = in;
    }
    const frames = try std.heap.page_allocator.alloc(rt.replay.Frame, inputs.len);
    defer std.heap.page_allocator.free(frames);
    const initial = spawnState(.complex, prng.random());
    var samples: [runs]f64 = undefined;
    for (&samples) |*sample| {
        const start = now(io);
        for (0..200) |_| std.mem.doNotOptimizeAway(rt.replay.run(&sim, initial, &inputs, frames));
        sample.* = @as(f64, @floatFromInt(now(io) - start)) / (200 * inputs.len);
    }
    const ns = median(&samples);
    try out.print("{s:<16} {d:>8.1} ns/tick {d:>10.2} Mticks/s (200-tick replays with frame capture)\n", .{ "replay", ns, 1e3 / ns });
}

const Shared = struct {
    world: rt.World,
    ticks: u32,
    seed: u64,
};

fn playerThread(shared: *const Shared, normal: *u64) void {
    var sim: rt.Simulator = .init(shared.world, .{ .policy = .hardened });
    var prng: Rng = .init(shared.seed);
    var states: [players]rt.State = undefined;
    var inputs: [players]rt.Input = @splat(.{});
    for (&states) |*s| s.* = spawnState(.complex, prng.random());
    var n: u64 = 0;
    for (0..shared.ticks) |t| for (&states, &inputs) |*s, *in| {
        nextInput(.complex, prng.random(), @intCast(t), in);
        n += @intFromBool(sim.tick(s, in).outcome == .normal);
    };
    normal.* = n;
}

/// Read-only grid view shared by every thread, so lookups are not counted.
const SharedGrid = struct {
    fn lookup(ptr: *anyopaque, pos: rt.BlockPos) ?rt.Block {
        const g: *const GridWorld = @ptrCast(@alignCast(ptr));
        const i = GridWorld.index(pos.x, pos.y, pos.z) orelse return null;
        return g.palette[g.cells[i]];
    }
    const vtable: rt.World.VTable = .{ .block = lookup };
};

fn benchThreads(io: Io, out: *Io.Writer) !void {
    const g = try std.heap.page_allocator.create(GridWorld);
    defer std.heap.page_allocator.destroy(g);
    g.* = .{};
    var prng: Rng = .init(7);
    buildWorld(g, .complex, prng.random());
    const cpus = @min(std.Thread.getCpuCount() catch 1, 64);
    var thread_counts = [_]usize{ 1, 2, 4, 8, cpus };
    var last: usize = 0;
    for (&thread_counts) |n| {
        if (n > cpus or n == last) continue;
        last = n;
        var threads: [64]std.Thread = undefined;
        var normals: [64]u64 = @splat(0);
        var shared: [64]Shared = undefined;
        const ticks = 600;
        const start = now(io);
        for (0..n) |i| {
            shared[i] = .{ .world = .{ .ptr = g, .vtable = &SharedGrid.vtable }, .ticks = ticks, .seed = i + 1 };
            threads[i] = try std.Thread.spawn(.{}, playerThread, .{ &shared[i], &normals[i] });
        }
        for (threads[0..n]) |t| t.join();
        const elapsed: f64 = @floatFromInt(now(io) - start);
        const total: f64 = @floatFromInt(n * players * ticks);
        var simulated: u64 = 0;
        for (normals[0..n]) |v| simulated += v;
        try out.print("threads={d:<3} players={d:<5} {d:>8.2} Mticks/s  ({d:.1} ns/tick/thread incl. input generation, {d:.1}% simulated)\n", .{
            n, n * players, total * 1e3 / elapsed, elapsed * @as(f64, @floatFromInt(n)) / total, @as(f64, @floatFromInt(simulated)) * 100 / total,
        });
    }
}

fn benchFixtures(io: Io, gpa: std.mem.Allocator, out: *Io.Writer) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const scenarios = try std.json.parseFromSliceLeaky([]fixture.Scenario, arena, @embedFile("fixtures"), .{});
    const prepared = try arena.alloc(fixture.Prepared, scenarios.len);
    var ticks: usize = 0;
    for (scenarios, prepared) |*sc, *p| {
        p.* = try fixture.prepare(sc, arena);
        ticks += p.steps.len;
    }
    const reps = 20;
    var samples: [runs]f64 = undefined;
    for (&samples) |*sample| {
        const start = now(io);
        for (0..reps) |_| for (prepared) |*p| {
            var sim = p.simulator();
            var state = p.initial;
            for (p.steps) |*step| std.mem.doNotOptimizeAway(fixture.Prepared.tick(&sim, &state, step));
        };
        sample.* = @as(f64, @floatFromInt(now(io) - start)) / @as(f64, @floatFromInt(reps * ticks));
    }
    const ns = median(&samples);
    try out.print("{s:<16} {d:>8.1} ns/tick {d:>10.2} Mticks/s ({d} scenarios, {d} ticks, hash-map world)\n", .{ "fixtures", ns, 1e3 / ns, scenarios.len, ticks });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buf);
    const out = &stdout.interface;
    try out.print("riptide {s} bench: {d} players x {d} ticks, median of {d} runs\n", .{ rt.version, players, ticks_per_player, runs });
    try out.print("sizeof State={d} B, Simulator={d} B\n", .{ @sizeOf(rt.State), @sizeOf(rt.Simulator) });
    try out.flush();
    inline for (@typeInfo(Workload).@"enum".field_names) |name| {
        try benchWorkload(io, @field(Workload, name), out);
        try out.flush();
    }
    try benchReplay(io, out);
    try benchFixtures(io, init.gpa, out);
    try out.flush();
    try benchThreads(io, out);
    try out.flush();
}
