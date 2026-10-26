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
    const standalone_options = b.addOptions();
    standalone_options.addOptionPath("miniscript", exe.getEmittedBin());
    const standalone_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/standalone_commands.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    standalone_tests.root_module.addOptions("executables", standalone_options);
    test_step.dependOn(&b.addRunArtifact(standalone_tests).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("LICENSE"), "share/licenses/chainwall/LICENSE").step);
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("THIRD_PARTY_NOTICES.md"), "share/licenses/chainwall/THIRD_PARTY_NOTICES.md").step);
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("LICENSES"),
        .install_dir = .prefix,
        .install_subdir = "share/licenses/chainwall/LICENSES",
    }).step);
    const build_cli = b.option(bool, "cli", "Build the Chainwall CLI") orelse true;
    const build_lsp = b.option(bool, "lsp", "Build the Lambdascript language server") orelse true;
    const smoke_tool = b.addExecutable(.{ .name = "installation-smoke", .root_module = b.createModule(.{
        .root_source_file = b.path("test/install_smoke.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    }) });
    const smoke = b.addRunArtifact(smoke_tool);
    const install_prefix: std.Build.LazyPath = .{ .relative = .{ .base = .install_prefix, .sub_path = "" } };
    smoke.addDirectoryArg(install_prefix);
    smoke.addArgs(&.{ if (build_cli) "cli" else "no-cli", if (build_lsp) "lsp" else "no-lsp" });
    smoke.step.dependOn(b.getInstallStep());
    b.step("smoke", "Check native installed binaries, documentation, skills and completions").dependOn(&smoke.step);
    const source_package_tool = b.addExecutable(.{ .name = "source-package-smoke", .root_module = b.createModule(.{
        .root_source_file = b.path("test/package_smoke.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    }) });
    const source_package = b.addRunArtifact(source_package_tool);
    source_package.addArg(b.graph.zig_exe);
    source_package.addDirectoryArg(b.path("."));
    source_package.has_side_effects = true;
    b.step("test-package", "Fetch, extract and build the manifest-filtered source package").dependOn(&source_package.step);
    const archive_name = b.fmt("chainwall-{s}-{s}.tar.gz", .{ @import("build.zig.zon").version, target.result.zigTriple(b.allocator) catch @panic("OOM") });
    const archive = b.addSystemCommand(&.{ "tar", "-czf" });
    const archive_path = archive.addOutputFileArg(archive_name);
    archive.addArg("-C");
    archive.addDirectoryArg(install_prefix);
    archive.addArgs(&.{ "bin", "share" });
    archive.step.dependOn(b.getInstallStep());
    const install_archive = b.addInstallFileWithDir(archive_path, .prefix, b.fmt("packages/{s}", .{archive_name}));
    b.step("package", "Create a versioned binary archive including notices and documentation").dependOn(&install_archive.step);
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
            const store_bench = b.addExecutable(.{ .name = "store-bench", .root_module = b.createModule(.{
                .root_source_file = b.path("src/cli/store_bench.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{ .{ .name = "miniscript", .module = module }, .{ .name = "zqlite", .module = sqlite.module("zqlite") } },
            }) });
            b.step("bench-store", "Measure point and paginated queries as journals grow").dependOn(&b.addRunArtifact(store_bench).step);
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
            const fake_cast = b.addExecutable(.{ .name = "cast", .root_module = b.createModule(.{
                .root_source_file = b.path("src/cli/test_cast.zig"),
                .target = target,
                .optimize = optimize,
            }) });
            const command_options = b.addOptions();
            command_options.addOptionPath("cli", cli.getEmittedBin());
            command_options.addOptionPath("cast", fake_cast.getEmittedBin());
            const command_tests = b.addTest(.{ .root_module = b.createModule(.{
                .root_source_file = b.path("src/cli/command_tests.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "miniscript", .module = module }},
            }) });
            command_tests.root_module.addOptions("executables", command_options);
            const commands = b.addRunArtifact(command_tests);
            b.step("test-commands", "Test complete CLI commands with Zig transports").dependOn(&commands.step);
            test_step.dependOn(&commands.step);
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
            b.getInstallStep().dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("editors/neovim"), .install_dir = .prefix, .install_subdir = "share/chainwall/editors/neovim" }).step);
            const editor_smoke = b.addExecutable(.{ .name = "editor-smoke", .root_module = b.createModule(.{ .root_source_file = b.path("test/editor_smoke.zig"), .target = target, .optimize = optimize }) });
            const editor_run = b.addRunArtifact(editor_smoke);
            editor_run.addArg(b.option([]const u8, "neovim", "Neovim executable for test-editor") orelse "nvim");
            editor_run.addFileArg(lsp.getEmittedBin());
            editor_run.addDirectoryArg(b.path("editors/neovim"));
            b.step("test-editor", "Test the native Neovim integration with the real LSP").dependOn(&editor_run.step);
            const run_lsp = b.addRunArtifact(lsp);
            run_lsp.addPassthruArgs();
            b.step("lsp", "Run the Lambdascript language server").dependOn(&run_lsp.step);
            test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = lsp_module })).step);
            const lsp_options = b.addOptions();
            lsp_options.addOptionPath("lsp", lsp.getEmittedBin());
            const protocol_tests = b.addTest(.{ .root_module = b.createModule(.{
                .root_source_file = b.path("src/lsp_transport_tests.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "miniscript", .module = module }},
            }) });
            protocol_tests.root_module.addOptions("executables", lsp_options);
            const protocol_run = b.addRunArtifact(protocol_tests);
            b.step("test-lsp", "Test the LSP executable over framed stdio").dependOn(&protocol_run.step);
            test_step.dependOn(&protocol_run.step);
        }
    }
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the compiler CLI").dependOn(&run.step);
    const fixture_tool = b.addExecutable(.{ .name = "fixtures", .root_module = b.createModule(.{
        .root_source_file = b.path("test/fixtures.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "miniscript", .module = module }},
    }) });
    const fixture_run = b.addRunArtifact(fixture_tool);
    fixture_run.addPassthruArgs();
    b.step("fixtures", "Verify or regenerate the compiler fixture corpus").dependOn(&fixture_run.step);
    test_step.dependOn(&b.addRunArtifact(fixture_tool).step);
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
