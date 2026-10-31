const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Omit debug symbols from build artifacts") orelse (optimize != .debug);

    const exe = b.addExecutable(.{
        .name = "aroute",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    // One test artifact per root file; add new ones here as modules appear.
    const tests = [_]*std.Build.Step.Compile{
        b.addTest(.{
            .name = "test-main",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
    };

    const test_step = b.step("test", "Run tests");
    for (tests) |t| test_step.dependOn(&b.addRunArtifact(t).step);

    const coverage_step = b.step("coverage", "Run tests with kcov coverage");
    const clean_coverage = b.addSystemCommand(&.{ "rm", "-rf", "coverage" });
    const mkdir_coverage = b.addSystemCommand(&.{ "mkdir", "-p", "coverage/merged" });
    mkdir_coverage.step.dependOn(&clean_coverage.step);

    const kcov_merge = b.addSystemCommand(&.{ "kcov", "--clean", "--merge", "coverage/merged" });
    for (tests) |t| {
        t.use_llvm = true;
        t.root_module.strip = false;
        const output_dir = b.fmt("coverage/{s}", .{t.name});
        const kcov_run = b.addSystemCommand(&.{ "kcov", "--clean" });
        kcov_run.addPrefixedDirectoryArg("--include-path=", b.path("src"));
        kcov_run.addArg("--exclude-pattern=/.zig/,/lib/zig/");
        kcov_run.addArg(output_dir);
        kcov_run.addArtifactArg(t);
        kcov_run.step.dependOn(&mkdir_coverage.step);
        kcov_merge.addArg(output_dir);
        kcov_merge.step.dependOn(&kcov_run.step);
    }
    coverage_step.dependOn(&kcov_merge.step);
}
