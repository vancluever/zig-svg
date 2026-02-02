// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi
const std = @import("std");

fn docsStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) *std.Build.Step {
    const dir = b.addInstallDirectory(.{
        .source_dir = b.addObject(.{
            .name = "svg",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/svg.zig"),
                .target = target,
                .optimize = .Debug,
            }),
        }).getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const in_tar = b.pathJoin(
        &.{ b.install_prefix, "docs", "sources.tar" },
    );
    const out_tar = b.pathJoin(
        &.{ b.install_prefix, "docs", "sources.tar.new" },
    );
    const tar = b.addSystemCommand(&.{"sh"});
    tar.addArgs(&.{
        "-c",
        b.fmt("cat {s} | tar --delete std builtin > {s}", .{ in_tar, out_tar }),
    });

    const mv = b.addSystemCommand(&.{ "mv", out_tar, in_tar });

    tar.step.dependOn(&dir.step);
    mv.step.dependOn(&tar.step);
    return &mv.step;
}

fn docsServeStep(b: *std.Build, docs_step: *std.Build.Step) *std.Build.Step {
    const server = b.addSystemCommand(&.{ "python3", "-m", "http.server" });
    // No idea how to access the build prefix otherwise right now, so we have
    // to set this manually
    server.setCwd(std.Build.LazyPath{
        .cwd_relative = b.pathJoin(&.{ b.install_prefix, "docs" }),
    });
    server.step.dependOn(docs_step);
    return &server.step;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    _ = b.addModule("svg", .{
        .root_source_file = b.path("src/svg.zig"),
    });
    const tests = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/svg.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    }));
    b.step("test", "Run unit tests").dependOn(&tests.step);
    const docs_step = docsStep(b, target);
    b.step("docs", "Generate documentation").dependOn(docs_step);
    b.step("docs-serve", "Serve documentation").dependOn(docsServeStep(b, docs_step));
}
