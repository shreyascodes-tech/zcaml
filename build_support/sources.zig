const std = @import("std");
const Build = std.Build;
const Compile = Build.Step.Compile;
const Index = @import("manifest.zig").Index;
const Config = @import("config.zig").Config;

pub const Sources = struct {
    b: *Build,
    ocaml: *Build.Dependency,
    runtime: *Compile,
    primitives: Build.LazyPath,
    index: *const Index,
    config: Config,
    generator: *Compile,
    outputs: std.StringHashMap(Build.LazyPath),

    pub fn init(
        b: *Build,
        ocaml: *Build.Dependency,
        runtime: *Compile,
        primitives: Build.LazyPath,
        index: *const Index,
        config: Config,
    ) Sources {
        const generator = b.addExecutable(.{
            .name = "compiler-source",
            .root_module = b.createModule(.{
                .target = b.graph.host,
                .optimize = .Debug,
                .root_source_file = b.path("tools/compiler_source.zig"),
            }),
        });
        return .{
            .b = b,
            .ocaml = ocaml,
            .runtime = runtime,
            .primitives = primitives,
            .index = index,
            .config = config,
            .generator = generator,
            .outputs = std.StringHashMap(Build.LazyPath).init(b.allocator),
        };
    }

    pub fn resolve(self: *Sources, path: []const u8) !Build.LazyPath {
        if (self.outputs.get(path)) |output| return output;
        const rule = self.index.generated.get(path) orelse return self.ocaml.path(path);
        const transform = rule.transform;

        if (std.mem.eql(u8, transform, "c_preprocess")) {
            const headers = self.config.cppHeaders(self.b);
            const cpp = self.b.addSystemCommand(&.{ self.b.graph.zig_exe, "cc", "-E", "-P", "-x", "c" });
            for (headers) |header_dir| {
                cpp.addArg("-I");
                cpp.addDirectoryArg(header_dir);
            }
            cpp.addArg("-I");
            cpp.addDirectoryArg(self.ocaml.path("runtime/caml"));
            cpp.addArg("-o");
            const output = cpp.addOutputFileArg(std.fs.path.basename(path));
            cpp.addFileArg(self.ocaml.path(rule.inputs[0]));
            try self.outputs.put(path, output);
            return output;
        }

        if (std.mem.eql(u8, transform, "ocamllex")) {
            const run = Build.Step.Run.create(self.b, "run boot/ocamllex");
            run.addArtifactArg(self.runtime);
            run.addFileArg(self.ocaml.path("boot/ocamllex"));
            run.addArgs(&.{ "-q", "-o" });
            const output = run.addOutputFileArg(std.fs.path.basename(path));
            run.addFileArg(self.ocaml.path(rule.inputs[0]));
            try self.outputs.put(path, output);
            return output;
        }

        const mode: []const u8 = blk: {
            if (std.mem.eql(u8, transform, "concat")) break :blk "concat";
            if (std.mem.eql(u8, transform, "menhir_rename")) break :blk "menhir";
            if (std.mem.eql(u8, transform, "menhir_mli")) break :blk "menhir-interface";
            if (std.mem.eql(u8, transform, "runtimedef")) break :blk "runtimedef";
            if (std.mem.eql(u8, transform, "bootstrap_opcodes")) break :blk "opcodes";
            if (std.mem.eql(u8, transform, "bootstrap_opcodes_interface")) break :blk "opcodes-interface";
            if (std.mem.eql(u8, path, "utils/config.common.ml")) break :blk "config-common";
            if (std.mem.eql(u8, path, "utils/config.generated.ml")) break :blk "config-generated";
            if (std.mem.eql(u8, transform, "copy")) break :blk "copy";
            return error.UnsupportedBootstrapTransform;
        };

        const run = self.b.addRunArtifact(self.generator);
        run.addArg(mode);
        for (rule.inputs) |input| {
            if (std.mem.eql(u8, input, "runtime/primitives")) {
                run.addFileArg(self.primitives);
            } else {
                run.addFileArg(try self.resolve(input));
            }
        }
        if (std.mem.eql(u8, mode, "config-common")) {
            run.addArg(self.index.data.magic_prefix);
            run.addArg(self.index.data.magic_version);
        } else if (std.mem.eql(u8, mode, "config-generated")) {
            self.config.addCompilerSubstitutions(self.b, run);
        }

        const output = run.addOutputFileArg(std.fs.path.basename(path));
        try self.outputs.put(path, output);
        return output;
    }
};
