// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2026 Chris Marchesi
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const svg = b.addModule("svg", .{
        .root_source_file = b.path("src/svg.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addRunArtifact(b.addTest(.{
        .root_module = svg,
    }));
    b.step("test", "Run unit tests").dependOn(&tests.step);
    var check_step = b.step("check", "Build, but don't run, unit tests");
    check_step.dependOn(&tests.step);
}
