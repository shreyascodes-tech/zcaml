const std = @import("std");
const Build = std.Build;

pub const Data = @import("../tools/manifest.zig");

pub const Index = struct {
    data: Data,
    groups: std.StringHashMap(Data.SourceGroup),
    archives: std.StringHashMap(Data.Archive),
    rules: std.StringHashMap(std.ArrayList([]const u8)),
    generated: std.StringHashMap(Data.GeneratedFile),

    pub fn init(b: *Build, data: Data) !Index {
        var index: Index = .{
            .data = data,
            .groups = std.StringHashMap(Data.SourceGroup).init(b.allocator),
            .archives = std.StringHashMap(Data.Archive).init(b.allocator),
            .rules = std.StringHashMap(std.ArrayList([]const u8)).init(b.allocator),
            .generated = std.StringHashMap(Data.GeneratedFile).init(b.allocator),
        };

        for (data.source_groups) |group| {
            if (index.groups.contains(group.name)) {
                std.log.err("duplicate OCaml source group in manifest: {s}", .{group.name});
                return error.DuplicateSourceGroup;
            }
            try index.groups.put(group.name, group);
        }
        for (data.archives) |entry| {
            if (index.archives.contains(entry.name)) {
                std.log.err("duplicate OCaml archive in manifest: {s}", .{entry.name});
                return error.DuplicateArchive;
            }
            if (entry.members.len == 0) {
                std.log.err("empty OCaml archive in manifest: {s}", .{entry.name});
                return error.EmptyArchive;
            }
            try index.archives.put(entry.name, entry);
        }
        for (data.dependencies) |rule| {
            if (rule.arch != null) continue;
            const slot = try index.rules.getOrPut(rule.output);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.appendSlice(b.allocator, rule.prerequisites);
        }
        for (data.generated_files) |rule| {
            if (rule.arch != null or rule.platform != null) continue;
            if (index.generated.contains(rule.output)) {
                std.log.err("duplicate OCaml generation rule in manifest: {s}", .{rule.output});
                return error.DuplicateGenerationRule;
            }
            try index.generated.put(rule.output, rule);
        }
        return index;
    }

    pub fn archive(self: *const Index, name: []const u8) !Data.Archive {
        return self.archives.get(name) orelse {
            std.log.err("missing OCaml archive in manifest: {s}", .{name});
            return error.MissingArchive;
        };
    }
};
