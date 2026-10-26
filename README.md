
# Riptide

A fast, deterministic Minecraft Bedrock movement simulator written in Zig 0.17.

Riptide reproduces Minecraft Bedrock's player movement physics for servers, proxies, and anticheats. It simulates movement and collisions without relying on client-reported positions, making it useful for movement validation, prediction, and replay.

Built on the work of [BedSim](https://github.com/oomph-ac/bedsim), Riptide has been validated against 188 differential scenarios covering 8,930 ticks. Known differences and accuracy limitations are documented in [ACCURACY.md](docs/ACCURACY.md).

## Features

- **Movement physics:** Walking, sprinting, sneaking, crawling, jumping, falling, and stepping.
- **Collision handling:** Swept AABB collisions, depenetration, edge detection, and complex block geometry.
- **Block interactions:** Ice, slime, honey, cobwebs, scaffolding, ladders, powder snow, and other special blocks.
- **Fluid physics:** Swimming, water currents, lava, bubble columns, and movement enchantments.
- **Advanced movement:** Elytra gliding, firework boosts, Riptide, knockback, teleports, and status effects.
- **Deterministic simulation:** Consistent floating-point behavior across supported platforms and build modes, with no heap allocations during simulation.
- **Debugging tools:** Per-tick results, confidence reporting, optional physics traces, and replay with divergence detection.
- **Integration:** Native Zig API and a C interface.

## Installation

Requires Zig 0.17.0.

```sh
zig fetch --save git+https://github.com/TrixNEW/Riptide
```

Add Riptide to your `build.zig`:

```zig
const riptide = b.dependency("riptide", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("riptide", riptide.module("riptide"));
```

## Usage

Create a simulator with a world provider and maintain a separate state for each player.

```zig
const rt = @import("riptide");

var sim: rt.Simulator = .init(world, .{ .policy = .hardened });
var state: rt.State = .{
    .pos = spawn,
    .on_ground = true,
};

// Process each PlayerAuthInput tick.
const result = sim.tick(&state, &.{
    .move = .{ .y = 1 },
    .rotation = .{
        .pitch = pitch,
        .head_yaw = head_yaw,
        .yaw = yaw,
    },
    .reported_pos = client_pos,
    .flags = .{
        .sprint_down = true,
        .start_jumping = jumped,
        .jumping = jump_held,
    },
});

switch (result.outcome) {
    .normal => {
        if (result.position_delta.len() > 0.03)
            correct(state.pos);
    },
    .unloaded, .query_limit => {},
    else => {},
}
```

Each simulator maintains approximately 92 KiB of reusable scratch memory. Instances can be reused across players without allocating during simulation. Use a separate simulator per thread.

See [docs/examples/basic.zig](docs/examples/basic.zig) for a working example.

## World Integration

Riptide uses a `World` interface to query blocks and their collision properties. Your implementation supplies block geometry, physics properties, and fluid information.

The simulator handles collision detection and world queries internally. Unknown or unloaded blocks are reported rather than treated as empty space.

Dynamic block shapes, including scaffolding and powder snow, are supported through the world's `dynamic_shape` callback.

A built-in `MapWorld` implementation is available for testing and prototyping.

## Movement Validation

Riptide separates movement simulation from anticheat enforcement. It calculates expected movement and reports differences without automatically flagging or punishing players.

Two simulation policies are available:

- **Vanilla:** Follows the client's movement behavior as closely as possible.
- **Hardened:** Adds server-side validation for certain client-controlled behaviors, including swimming state.

Server-authorized movement events can be applied directly to player state:

| Event | API |
|---|---|
| Knockback and external motion | `state.queueMotion()` |
| Teleports | `state.queueTeleport()` |
| Firework boosts | `state.queueFireworkBoost()` |
| Riptide activation | `state.riptide_ready` |
| Effects, equipment, and abilities | `State` fields |

Each simulation tick returns an outcome describing whether movement was simulated normally, interrupted, or handled differently.

Invalid inputs, unloaded terrain, and exceeded query limits are reported explicitly to prevent unreliable movement comparisons.

## Accuracy

Riptide uses 32-bit floating-point calculations and preserves the client's operation order where reproduced.

Its differential test suite compares results against a pinned version of BedSim across 188 scenarios and 8,930 ticks. These fixtures must match bit for bit across supported build modes.

Testing currently covers Windows and Linux on x86-64.

Matching BedSim does not guarantee identical behavior to the Minecraft client. [ACCURACY.md](docs/ACCURACY.md) documents verified mechanics, intentional differences, and areas requiring further validation.

## Performance

Benchmarks were collected on an AMD Ryzen 5 5500 using `ReleaseFast`, with results reported in nanoseconds per tick.

| Workload | Windows 11 | Linux (WSL2) |
|---|---:|---:|
| Sprinting on flat ground | 781 | 786 |
| Complex block geometry | 886 | 883 |
| Water swimming | 671 | 665 |
| Dense collision geometry | 1,019 | 1,035 |

### Comparison with BedSim

Both simulators were tested against the same 8,930-tick fixture suite using equivalent hash-map worlds.

| Simulator | Windows | Linux (WSL2) | Heap allocations/tick |
|---|---:|---:|---:|
| **Riptide** | **1,038 ns** | **985 ns** | **0** |
| BedSim (Go) | 7,401 ns | 5,721 ns | 11 |

Riptide was approximately **5.8–7.1× faster** in this comparison.

The BedSim allocation count includes allocations introduced by its world adapter, so these results should not be interpreted as a direct comparison of the physics implementations alone.

Riptide also uses a per-tick block cache to reduce redundant world lookups.

Run the benchmarks locally with:

```sh
zig build bench -Doptimize=ReleaseFast
```

## Development

```sh
zig build test
zig build test -Doptimize=ReleaseFast
zig build bench -Doptimize=ReleaseFast
zig build lib
```

The test suite covers physics behavior, differential fixtures, concurrency, and the C API.

## Limitations

Riptide focuses on player movement. Vehicle physics, creative and spectator flight, no-clip movement, piston interactions, and entity collisions are not currently simulated.

Some mechanics still require additional validation against real Bedrock client behavior. See [ACCURACY.md](docs/ACCURACY.md) for details.

## License

Licensed under [Apache-2.0](LICENSE).

Riptide incorporates work derived from BedSim, licensed under MIT. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution.
