// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    _ = b.addModule("svg", .{
        .root_source_file = b.path("src/svg.zig"),
    });
    const tests = b.addRunArtifact(b.addTest(.{
        .root_source_file = .{ .path = "src/svg.zig" },
        .target = target,
        .optimize = .Debug,
    }));
    b.step("test", "Run unit tests").dependOn(&tests.step);
}
