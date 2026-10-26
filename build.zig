const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("riptide", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit and fixture tests");
    const unit = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit).step);

    const fixture = b.createModule(.{
        .root_source_file = b.path("tests/fixture.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "riptide", .module = mod }},
    });
    const fixtures = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "riptide", .module = mod }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(fixtures).step);

    const bench = b.addExecutable(.{
        .name = "riptide-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = if (optimize == .debug) .fast else optimize,
            .imports = &.{
                .{ .name = "riptide", .module = mod },
                .{ .name = "fixture", .module = fixture },
            },
        }),
    });
    bench.root_module.addAnonymousImport("fixtures", .{ .root_source_file = b.path("tests/fixtures/bedsim.json") });
    b.step("bench-exe", "Build the benchmark executable").dependOn(&b.addInstallArtifact(bench, .{}).step);
    const bench_step = b.step("bench", "Run benchmarks");
    const run_bench = b.addRunArtifact(bench);
    run_bench.addPassthruArgs();
    bench_step.dependOn(&run_bench.step);

    const example = b.addExecutable(.{
        .name = "riptide-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "riptide", .module = mod }},
        }),
    });
    const example_step = b.step("example", "Run the basic example");
    example_step.dependOn(&b.addRunArtifact(example).step);
}
