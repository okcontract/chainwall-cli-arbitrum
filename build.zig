const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_step = b.step("test", "Run standalone library and parity fixture tests");
    const module = b.addModule("miniscript", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "miniscript",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "miniscript", .module = module }},
        }),
    });
    b.installArtifact(exe);
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("LICENSE"), "share/licenses/chainwall/LICENSE").step);
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("THIRD_PARTY_NOTICES.md"), "share/licenses/chainwall/THIRD_PARTY_NOTICES.md").step);
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("LICENSES"),
        .install_dir = .prefix,
        .install_subdir = "share/licenses/chainwall/LICENSES",
    }).step);
    const build_cli = b.option(bool, "cli", "Build the Chainwall CLI") orelse true;
    const build_lsp = b.option(bool, "lsp", "Build the Lambdascript language server") orelse true;
    if (build_cli or build_lsp) {
        const sqlite = b.dependency("zqlite", .{
            .target = target,
            .optimize = optimize,
            .sqlite3 = &[_][]const u8{ "-std=c99", "-DSQLITE_DQS=0", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DEFAULT_FILE_PERMISSIONS=0600" },
        });
        b.getInstallStep().dependOn(&b.addInstallFile(sqlite.path("LICENSE"), "share/licenses/chainwall/zqlite.txt").step);
        // Preserve the CLI's existing lowercase manual path and the source
        // filename used by links in the companion guides.
        b.getInstallStep().dependOn(&b.addInstallFile(b.path("MANUAL.md"), "share/doc/chainwall/manual.md").step);
        b.getInstallStep().dependOn(&b.addInstallFile(b.path("MANUAL.md"), "share/doc/chainwall/MANUAL.md").step);
        for ([_][]const u8{ "README.md", "CONTRIBUTING.md", "CLI.md", "COMPILER.md", "LSP.md", "LICENSE", "THIRD_PARTY_NOTICES.md" }) |file| {
            b.getInstallStep().dependOn(&b.addInstallFile(b.path(file), b.fmt("share/doc/chainwall/{s}", .{file})).step);
        }
        b.getInstallStep().dependOn(&b.addInstallDirectory(.{
            .source_dir = b.path("LICENSES"),
            .install_dir = .prefix,
            .install_subdir = "share/doc/chainwall/LICENSES",
        }).step);
        b.getInstallStep().dependOn(&b.addInstallDirectory(.{
            .source_dir = b.path("skills"),
            .install_dir = .prefix,
            .install_subdir = "share/doc/chainwall/skills",
        }).step);
        if (build_cli) {
            const cli_module = b.createModule(.{
                .root_source_file = b.path("src/cli/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{ .{ .name = "miniscript", .module = module }, .{ .name = "zqlite", .module = sqlite.module("zqlite") } },
            });
            // Embed the versioned protocol snapshots shipped in this repository.
            cli_module.addAnonymousImport("factory-addresses", .{
                .root_source_file = b.path("src/cli/artifacts/factory-addresses.json"),
            });
            cli_module.addAnonymousImport("input-schemas", .{
                .root_source_file = b.path("src/cli/artifacts/input-schemas.json"),
            });
            const cli = b.addExecutable(.{ .name = "chainwall", .root_module = cli_module });
            b.installArtifact(cli);
            b.getInstallStep().dependOn(&b.addInstallFile(b.path("src/cli/chainwall.fish"), "share/fish/vendor_completions.d/chainwall.fish").step);
            b.getInstallStep().dependOn(&b.addInstallFile(b.path("src/cli/_chainwall"), "share/zsh/site-functions/_chainwall").step);
            const run_cli = b.addRunArtifact(cli);
            run_cli.addPassthruArgs();
            b.step("chainwall", "Run the Registry CLI").dependOn(&run_cli.step);
            test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = cli_module })).step);
        }
        if (build_lsp) {
            const lsp_module = b.createModule(.{
                .root_source_file = b.path("src/lsp.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{ .{ .name = "miniscript", .module = module }, .{ .name = "zqlite", .module = sqlite.module("zqlite") } },
            });
            const lsp = b.addExecutable(.{ .name = "chainwall-lsp", .root_module = lsp_module });
            b.installArtifact(lsp);
            const run_lsp = b.addRunArtifact(lsp);
            run_lsp.addPassthruArgs();
            b.step("lsp", "Run the Lambdascript language server").dependOn(&run_lsp.step);
            test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = lsp_module })).step);
        }
    }
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the compiler CLI").dependOn(&run.step);
    const tests = b.addRunArtifact(b.addTest(.{ .root_module = module }));
    test_step.dependOn(&tests.step);
    const integration = b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "miniscript", .module = module }},
    }) }));
    test_step.dependOn(&integration.step);
}
