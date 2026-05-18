const std = @import("std");

const Renderer = enum { vulkan, webgpu, opengl };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = b.addOptions();

    const renderer = parseRendererOption(b);
    options.addOption(Renderer, "renderer", renderer);

    // SDL3 path - only needed on Windows where SDL3 isn't system-installed.
    const sdl3_path = b.option([]const u8, "sdl3", "Path to SDL3 (Windows only)") orelse
        b.graph.env_map.get("SDL3_DIR") orelse
        probeSdl3();

    // Vulkan SDK path - used for vk.xml (code generation) and glslc (shader compilation).
    // Resolved from: -Dvulkan-sdk option -> VULKAN_SDK env var -> platform-specific probe.
    const vulkan_sdk = b.option([]const u8, "vulkan-sdk", "Path to Vulkan SDK") orelse
        b.graph.env_map.get("VULKAN_SDK") orelse
        probeVulkanSdk(b.allocator) orelse
        @panic("Vulkan SDK not found. Set VULKAN_SDK env var or pass -Dvulkan-sdk=<path>.");

    // Flecs ECS dependency.
    const zflecs = b.dependency("zflecs", .{
        .target = target,
        .optimize = optimize,
    });

    // SDL3 bindings dependency.
    const zsdl = b.dependency("zsdl", .{
        .target = target,
        .optimize = optimize,
    });

    // zgui (Dear ImGui) - SDL3 + Vulkan backend for debug overlays.
    const vulkan_include_path = std.fmt.allocPrint(b.allocator, "{s}/include", .{vulkan_sdk}) catch @panic("OOM");
    const zgui_dep = b.dependency("zgui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3_vulkan,
        .vulkan_include = vulkan_include_path,
    });
    const zgui_module = zgui_dep.module("root");
    const imgui_lib = zgui_dep.artifact("imgui");

    // Tracy profiling bindings. Enabled via -Denable_ztracy=true on the parent
    // build; defaults to no-op stubs otherwise. backend.zig references tracy
    // unconditionally; stubs compile out to zero runtime cost.
    const ztracy_dep = b.dependency("ztracy", .{
        .target = target,
        .optimize = optimize,
    });
    const ztracy_module = ztracy_dep.module("root");
    // SDL3 C headers needed by imgui_impl_sdl3.cpp on macOS (Homebrew install).
    switch (target.result.os.tag) {
        .macos => imgui_lib.addSystemIncludePath(.{ .cwd_relative = "/usr/local/opt/sdl3/include" }),
        else => {},
    }

    // Vulkan bindings (generates idiomatic Zig from vk.xml at build time).
    // Uses vendored vk.xml (1.3.296) because vulkan-zig at bed9e2d cannot parse 1.4 registry.
    // The vendored registry is only for code generation - runtime uses the installed SDK.
    const vulkan_dep = b.dependency("vulkan", .{
        .registry = @as(std.Build.LazyPath, .{ .cwd_relative = b.pathFromRoot("vendor/vulkan/vk.xml") }),
    });
    const vulkan_module = vulkan_dep.module("vulkan-zig");

    // Expose the engine as a module for the parent build.
    // The engine does NOT compile or embed any game shaders.
    // Game code compiles its own shaders and passes SPIR-V bytes via MaterialDef[].
    const engine_module = b.addModule("engine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine_module.addOptions("build_options", options);
    engine_module.addImport("zflecs", zflecs.module("root"));
    engine_module.addImport("zsdl3", zsdl.module("zsdl3"));
    engine_module.addImport("vulkan", vulkan_module);
    engine_module.addImport("zgui", zgui_module);
    engine_module.addImport("ztracy", ztracy_module);
    addSdl3IncludePaths(engine_module, target.result.os.tag, sdl3_path);

    // Engine tests.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addOptions("build_options", options);
    test_module.addImport("zflecs", zflecs.module("root"));
    test_module.addImport("zsdl3", zsdl.module("zsdl3"));
    test_module.addImport("vulkan", vulkan_module);
    test_module.addImport("zgui", zgui_module);
    test_module.addImport("ztracy", ztracy_module);
    addSdl3IncludePaths(test_module, target.result.os.tag, sdl3_path);

    const engine_tests = b.addTest(.{
        .root_module = test_module,
    });
    engine_tests.linkLibrary(zflecs.artifact("flecs"));
    engine_tests.linkLibrary(imgui_lib);
    linkSdl3(engine_tests, sdl3_path);
    linkVulkan(engine_tests, vulkan_sdk);
    linkZstd(engine_tests);

    const run_engine_tests = b.addRunArtifact(engine_tests);

    const test_step = b.step("test", "Run engine tests");
    test_step.dependOn(&run_engine_tests.step);
}

/// Add SDL3 C include paths to a module (needed for @cImport in backend.zig).
fn addSdl3IncludePaths(module: *std.Build.Module, os: std.Target.Os.Tag, sdl3_opt: ?[]const u8) void {
    switch (os) {
        .macos => module.addIncludePath(.{ .cwd_relative = "/usr/local/opt/sdl3/include" }),
        .windows => {
            if (sdl3_opt) |sdl3| {
                const b = module.owner;
                const inc_path = std.fmt.allocPrint(b.allocator, "{s}/include", .{sdl3}) catch @panic("OOM");
                module.addIncludePath(.{ .cwd_relative = inc_path });
            }
        },
        else => {},
    }
}

/// Link the SDL3 system library for a compile step.
/// On macOS (Homebrew Intel), SDL3 lives under /usr/local/opt/sdl3.
/// On Windows, sdl3_path must point to the SDL3 install root (with include/ and lib/).
pub fn linkSdl3(step: *std.Build.Step.Compile, sdl3_opt: ?[]const u8) void {
    const b = step.step.owner;
    switch (step.rootModuleTarget().os.tag) {
        .macos => {
            step.addLibraryPath(.{ .cwd_relative = "/usr/local/opt/sdl3/lib" });
            step.linkSystemLibrary("SDL3");
            step.root_module.addRPathSpecial("@executable_path");
        },
        .linux => {
            step.linkSystemLibrary("SDL3");
            step.root_module.addRPathSpecial("$ORIGIN");
        },
        .windows => {
            if (sdl3_opt) |sdl3| {
                const lib_path = std.fmt.allocPrint(b.allocator, "{s}/lib/win32-x64", .{sdl3}) catch @panic("OOM");
                const inc_path = std.fmt.allocPrint(b.allocator, "{s}/include", .{sdl3}) catch @panic("OOM");
                step.addLibraryPath(.{ .cwd_relative = lib_path });
                step.root_module.addIncludePath(.{ .cwd_relative = inc_path });
            }
            step.linkSystemLibrary("SDL3");
        },
        else => {},
    }
}

/// Link the Vulkan loader library for a compile step.
/// Also adds the SDL3 include path so @cImport(SDL_vulkan.h) resolves.
pub fn linkVulkan(step: *std.Build.Step.Compile, vulkan_sdk: []const u8) void {
    const b = step.step.owner;
    switch (step.rootModuleTarget().os.tag) {
        .macos => {
            const lib_path = std.fmt.allocPrint(b.allocator, "{s}/lib", .{vulkan_sdk}) catch @panic("OOM");
            step.addLibraryPath(.{ .cwd_relative = lib_path });
            step.linkSystemLibrary("vulkan");
            step.addRPath(.{ .cwd_relative = lib_path });
            step.root_module.addIncludePath(.{ .cwd_relative = "/usr/local/opt/sdl3/include" });
        },
        .linux => {
            step.linkSystemLibrary("vulkan");
        },
        .windows => {
            const lib_path = std.fmt.allocPrint(b.allocator, "{s}/Lib", .{vulkan_sdk}) catch @panic("OOM");
            const inc_path = std.fmt.allocPrint(b.allocator, "{s}/Include", .{vulkan_sdk}) catch @panic("OOM");
            step.addLibraryPath(.{ .cwd_relative = lib_path });
            step.root_module.addIncludePath(.{ .cwd_relative = inc_path });
            step.linkSystemLibrary("vulkan-1");
        },
        else => {},
    }
}

/// Link the zstd compression library for a compile step.
/// On macOS (Homebrew), libzstd lives under /usr/local/opt/zstd.
/// On Linux, install via libzstd-dev or similar.
pub fn linkZstd(step: *std.Build.Step.Compile) void {
    switch (step.rootModuleTarget().os.tag) {
        .macos => {
            step.addLibraryPath(.{ .cwd_relative = "/usr/local/opt/zstd/lib" });
            step.linkSystemLibrary("zstd");
        },
        .linux => {
            step.linkSystemLibrary("zstd");
        },
        .windows => {
            step.linkSystemLibrary("zstd");
        },
        else => {},
    }
}

/// Probe known SDL3 install locations. Only needed on Windows - macOS/Linux use system paths.
fn probeSdl3() ?[]const u8 {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag != .windows) return null;

    inline for (.{
        "C:/SDL3",
        "C:/SDL-v3.4.2",
        "C:/Libraries/SDL3",
    }) |p| {
        if (std.fs.cwd().statFile(p ++ "/include/SDL3/SDL.h")) |_| return p else |_| {}
    }
    return null;
}

/// Probe known Vulkan SDK install locations per platform.
/// On Windows: C:/VulkanSDK/<version>  (e.g. C:/VulkanSDK/1.4.341.1)
/// On macOS:   ~/VulkanSDK/<version>/macOS
/// On Linux:   system paths (no version subdir needed)
/// Returns null if no SDK found - caller should @panic with a helpful message.
fn probeVulkanSdk(allocator: std.mem.Allocator) ?[]const u8 {
    const builtin = @import("builtin");

    switch (builtin.os.tag) {
        .windows => {
            return probeVersionedDir(allocator, "C:/VulkanSDK", null, "Bin/glslc.exe");
        },
        .macos => {
            const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
            defer allocator.free(home);
            const parent = std.fmt.allocPrint(allocator, "{s}/VulkanSDK", .{home}) catch return null;
            defer allocator.free(parent);
            return probeVersionedDir(allocator, parent, "macOS", "bin/glslc");
        },
        .linux => {
            const paths: []const []const u8 = &.{ "/usr/share/vulkan", "/usr/local/share/vulkan" };
            for (paths) |p| {
                if (std.fs.cwd().openDir(p, .{})) |*dir| {
                    @constCast(dir).close();
                    return p;
                } else |_| {}
            }
            return null;
        },
        else => return null,
    }
}

/// Scan a parent directory for versioned subdirectories, pick the latest valid one.
/// A version dir is valid if it contains `validate_file` (e.g. "Bin/glslc.exe").
/// Returns "parent/version" or "parent/version/suffix" if suffix is non-null.
fn probeVersionedDir(allocator: std.mem.Allocator, parent: []const u8, suffix: ?[]const u8, validate_file: []const u8) ?[]const u8 {
    var dir = std.fs.cwd().openDir(parent, .{ .iterate = true }) catch return null;
    defer dir.close();

    // Collect version dirs, pick the latest (lexicographically highest).
    var best: ?[]const u8 = null;
    var iter = dir.iterate();
    while (iter.next() catch return null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0 or entry.name[0] < '0' or entry.name[0] > '9') continue;

        // Build candidate path and validate it has the required file.
        const candidate = if (suffix) |s|
            std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ parent, entry.name, s }) catch continue
        else
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, entry.name }) catch continue;

        // Check that the validate_file exists under the candidate.
        const check_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ candidate, validate_file }) catch {
            allocator.free(candidate);
            continue;
        };
        defer allocator.free(check_path);

        if (std.fs.cwd().statFile(check_path)) |_| {
            // Valid candidate - keep it if it's lexicographically greater than best.
            if (best) |prev| {
                if (std.mem.order(u8, entry.name, prev) == .gt) {
                    best = entry.name;
                } else {
                    allocator.free(candidate);
                    continue;
                }
            }
            best = entry.name;
        } else |_| {
            allocator.free(candidate);
        }
    }

    if (best) |version| {
        if (suffix) |s| {
            return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ parent, version, s }) catch return null;
        } else {
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, version }) catch return null;
        }
    }
    return null;
}

fn parseRendererOption(b: *std.Build) Renderer {
    const rawOption = b.option([]const u8, "backend", "The rendering backend to use (vulkan, webgpu, opengl)") orelse "vulkan";

    if (std.mem.eql(u8, rawOption, "vulkan")) {
        return .vulkan;
    } else if (std.mem.eql(u8, rawOption, "webgpu")) {
        @panic("webgpu is not implemented yet");
        //return .webgpu;
    } else if (std.mem.eql(u8, rawOption, "opengl")) {
        @panic("opengl is not implemented yet");
        //return .opengl;
    } else {
        @panic("Invalid backend option. Use -Dbackend=vulkan|webgpu|opengl");
    }
}
