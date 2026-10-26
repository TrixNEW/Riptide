# Riptide

A deterministic Minecraft Bedrock player movement simulator in Zig 0.17.

Riptide reproduces the Bedrock client's movement physics on the server, so a
server, proxy, bot, or anticheat can compute authoritative positions and compare
them with what clients report. It is derived from
[BedSim](https://github.com/oomph-ac/bedsim) and matches it bit for bit on 188
differential scenarios, with the deliberate differences listed in
[docs/ACCURACY.md](docs/ACCURACY.md).

- Walking, sprinting, sneaking, crawling, jumping, falling, stepping, sneak
  edges, swept AABB collision, and depenetration
- Ice, slime, beds, honey, soul sand, cobwebs, berry bushes, powder snow,
  ladders, vines, scaffolding, and bubble columns
- Water and lava, currents, swimming, Depth Strider, Dolphin's Grace, and exit
  boosts
- Elytra gliding with firework boosts, Riptide, knockback, and teleports
- Jump Boost, Levitation, Slow Falling, Weaving, Soul Speed, and Swift Sneak
- No allocations, no global state, and bit-identical results across build modes
  and threads
- Per-tick outcomes, a confidence level, an optional stage trace, and replay
  with divergence search
- A C interface (`include/riptide.h`)

## Install

```sh
zig fetch --save git+https://github.com/TrixNEW/Riptide
```

```zig
const riptide = b.dependency("riptide", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("riptide", riptide.module("riptide"));
```

Requires Zig 0.17.0. Tested on Windows and Linux (x86-64).

## Usage

```zig
const rt = @import("riptide");

var sim: rt.Simulator = .init(world, .{ .policy = .hardened });
var state: rt.State = .{ .pos = spawn, .on_ground = true };

// Once per PlayerAuthInput.
const result = sim.tick(&state, &.{
    .move = .{ .y = 1 },
    .rotation = .{ .pitch = pitch, .head_yaw = head_yaw, .yaw = yaw },
    .reported_pos = client_pos,
    .flags = .{ .sprint_down = true, .start_jumping = jumped, .jumping = jump_held },
});
switch (result.outcome) {
    .normal => if (result.position_delta.len() > 0.03) correct(state.pos),
    .unloaded, .query_limit => {}, // no authoritative answer this tick
    else => {},
}
```

A `Simulator` owns about 92 KiB of scratch memory and never allocates. Use one
per thread and pass any number of `State`s through it. `State` is plain data, so
copying it clones it. See [examples/basic.zig](examples/basic.zig) (`zig build
example`).

### World

Provide a `World` with one function: the block data at a cell, or `null` when
the cell is not loaded.

```zig
fn lookup(ptr: *anyopaque, pos: rt.BlockPos) ?rt.Block {
    const chunks: *Chunks = @ptrCast(@alignCast(ptr));
    const b = chunks.get(pos) orelse return null;
    return .{
        .shape = shapes.of(b),                       // block-local boxes
        .semantics = .fromName(b.name),              // or your own table
        .liquid = b.liquid,                          // either layer
        .solid_faces = faces.of(b),                  // closes liquid flow
        .flow_barrier = shapes.of(b).len != 0,
    };
}
const world: rt.World = .{ .ptr = &chunks, .vtable = &.{ .block = lookup } };
```

The simulator performs its own broad phase over these cells, so collision,
support, and liquid probes always agree. Shapes must lie within the cell
horizontally and below 1.5 vertically, and they must stay unchanged during a
`tick` call. Blocks whose shape depends on the player, such as scaffolding and
powder snow, set `dynamic_shape` and are resolved through
`VTable.dynamic_shape` with a `CollisionContext`. `MapWorld` is a hash-map world
for tests and prototyping.

### Trust and server events

Client flags drive input, but they never grant physics on their own.

| Server event | API |
| --- | --- |
| SetActorMotion, knockback, explosions | `state.queueMotion(vel)` (the latest wins) |
| Teleports (instant or smoothed) | `state.queueTeleport(pos, smoothed_ticks)` |
| A validated firework use | `state.queueFireworkBoost()` |
| A validated charged Riptide release | `state.riptide_ready = true` for the tick |
| Abilities, effects, equipment, attributes | the `State` fields `trust_fly_status`, `effects`, `equipment`, `movement_speed` |

`Policy` holds the rules that intentionally differ from the client. There are no
defaults, so pick one explicitly:

- `.vanilla` follows the client exactly, including its swimming flag.
- `.hardened` keeps the swim hitbox and water travel only within 10 ticks of
  server-observed water. A client that latches the flag cannot get zero gravity
  or a 0.6-block hitbox.

The core decides movement, not punishment. `rt.Correction` is an optional
helper that compares a result's deltas with thresholds.

### Outcomes

| Outcome | Meaning |
| --- | --- |
| `normal` | Physics ran. |
| `teleport` | A queued teleport moved the entity. |
| `client_authoritative` | Flying, creative, spectator, no-clip, or dead. The state follows the client. |
| `unloaded` | A required cell was unknown. The pose and position are kept and velocity is cleared. |
| `immobile` | The entity is immobile or not ready. |
| `mounted` | Vehicle physics are not simulated. The state follows the client. |
| `invalid_input` | NaN, infinity, or an out-of-range input or state. Nothing changes. |
| `invalid_world` | The world returned invalid block data. |
| `query_limit` | The sweep or coordinates exceed the safe query bounds. |

`result.mechanics` lists what took part in the tick, and `result.confidence()`
grades its evidence as `decompiled`, `ported`, or `uncertain`.

### Replay and debugging

```zig
var frames: [64]rt.replay.Frame = undefined;
const end = rt.replay.run(&sim, state, inputs, &frames); // state is not modified
const tick = rt.replay.firstDivergence(results_a, results_b, 0); // 0 = bit-exact

var events: [256]rt.TraceEvent = undefined;
var trace: rt.Trace = .init(&events);
sim.trace = &trace; // records every physics stage; null costs one branch
```

## Accuracy

Physics use f32 with the client's operation order. The lookup-table sine is used
where the client uses it, and a correctly rounded `sinf` is used for movement
input. The fixtures in `tests/fixtures/bedsim.json` are regenerated from a
pinned BedSim by `tools/oracle` (Go). CI fails if they drift. Every tick must
match bit for bit, and the fixtures pass on Windows and Linux in all build
modes.

No new real-client traces were captured for this release.
[docs/ACCURACY.md](docs/ACCURACY.md) lists what is verified against real
Bedrock, what only matches BedSim, the deliberate differences, and the open
questions.

## Performance

Measured with `zig build bench -Doptimize=ReleaseFast` on an AMD Ryzen 5 5500
(6 cores, 12 threads) desktop under normal background load. Each number is the
median of five runs, and the table shows the median of three invocations. Grid
workloads use a dense palette world with 64 players over 1,500 ticks each.

| Workload | Windows 11 ns/tick | Linux (WSL2) ns/tick |
| --- | ---: | ---: |
| flat ground, sprinting | 781 | 786 |
| complex geometry (slabs, stairs, fences, ice) | 886 | 883 |
| water swimming | 671 | 665 |
| lava | 956 | 943 |
| climbing and special blocks | 802 | 847 |
| Elytra with boosts¹ | 621 | 617 |
| dense multi-box collision | 1,019 | 1,035 |
| 200-tick replay with frame capture | 925 | 913 |

¹ About a third of glide ticks leave the loaded area and end early as `unloaded`.

Throughput with independent simulators per thread (complex workload, input
generation included): 1.0 Mticks/s on one thread, 3.9 on four and 6.4-6.7 on
twelve, on both systems.

**Against BedSim (Go).** Both run the same 188 fixture scenarios (8,930 ticks)
on equivalent hash-map worlds. Worlds and inputs are prepared before timing.

| | Windows ns/tick | Linux ns/tick | Heap allocations per tick |
| --- | ---: | ---: | ---: |
| Riptide | 1,038 | 985 | 0 |
| BedSim (Go 1.26.1 / 1.27.3) | 7,401 | 5,721 | 11 |

Part of BedSim's allocation count comes from the oracle's world adapter, which
allocates collision slices per call as many Go adapters do. Riptide's tick path
cannot allocate: neither `Simulator` nor `tick` takes an allocator. A per-call
block cache cut world lookups from about 68 to 12 per tick. `State` is 372
bytes and `Simulator` is about 92 KiB.

## Development

```sh
zig build test                        # unit, property, fixture, concurrency, C API
zig build test -Doptimize=ReleaseFast
zig build bench -Doptimize=ReleaseFast
zig build lib                         # static library in zig-out/lib, header in zig-out/include
sh tools/oracle/setup.sh && (cd tools/oracle && go run . -out ../../tests/fixtures/bedsim.json)
```

## Limitations

- Creative and spectator flight, no-clip, and vehicles are not simulated.
- Pistons and entity collision are not modelled. Moving shapes can be supplied
  through `dynamic_shape`.
- Item-use slowdown is a single modifier. Pass `Input.item_use_modifier` for
  exact values.
- Only x86-64 Windows and Linux are tested.

## License

Apache-2.0. The physics derive from BedSim (MIT), and its notice is in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
