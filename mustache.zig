const std = @import("std");

pub fn render(allocator: *std.mem.Allocator, comptime template: []const u8, data: anytype) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    try renderTo(template, data, buf.writer());
    return buf.toOwnedSlice();
}

pub fn renderTo(comptime template: []const u8, data: anytype, writer: anytype) !void {
    comptime var renderer = Renderer{};
    try renderer.renderInternal(template, data, writer, null);
}

const Renderer = struct {
    delim_start: []const u8 = "{{",
    delim_end: []const u8 = "}}",

    fn renderInternal(
        comptime self: *Renderer,
        comptime template: []const u8,
        data: anytype,
        writer: anytype,
        comptime start_tag: ?[]const u8,
    ) !void {
        comptime var idx: usize = 0;
        inline while (true) {
            // Find the next tag
            comptime const opt_start = std.mem.indexOfPos(u8, template, idx, self.delim_start);
            if (opt_start == null) {
                try writer.writeAll(template[idx..]);
                return;
            }
            comptime var start = opt_start.?;

            // Write the literal portion
            try writer.writeAll(template[idx..start]);
            start += self.delim_start.len;

            // Find the end of the tag
            comptime var end = std.mem.indexOfPos(u8, template, start, self.delim_end) orelse {
                @compileError("Syntax error: missing end delimiter");
            };
            comptime var end_delim_len = self.delim_end.len;

            // Classify the tag
            const tag_type: TagType = switch (template[start]) {
                '{' => blk: {
                    if (comptime !std.mem.eql(u8, self.delim_end, "}}")) {
                        @compileError("Syntax error: triple mustache not supported with overridden delimiters");
                    }
                    if (end + self.delim_end.len > template.len or template[end + 2] != '}') {
                        @compileError("Syntax error: missing '}' in triple mustache");
                    }
                    end_delim_len += 1;
                    break :blk .unescaped;
                },

                '=' => blk: {
                    if (template[end - 1] != '=') {
                        @compileError("Syntax error: missing '=' at end of set delimiter tag");
                    }
                    end -= 1;
                    end_delim_len += 1;
                    break :blk .set_delim;
                },

                '&' => .unescaped,
                '#' => .section,
                '^' => .inverted,
                '/' => .end_section,
                '!' => .comment,
                '>' => .partial,

                else => blk: {
                    start -= 1;
                    break :blk .variable;
                },
            };

            idx = end + end_delim_len; // Skip over the end delimiter
            comptime const tag_name = std.mem.trim(u8, template[start + 1 .. end], " \t\n");

            // Act based on the tag type
            switch (tag_type) {
                .variable => try writeValue(writer, getField(data, tag_name)),
                .unescaped => try writeValueUnescaped(writer, getField(data, tag_name)),

                .section => {
                    comptime const section_end = self.findEndTag(template, idx, tag_name);
                    try self.renderSection(template[idx..section_end], data, writer, tag_name);
                    idx = section_end;
                },
                .inverted => {
                    comptime const section_end = self.findEndTag(template, idx, tag_name);
                    try self.renderInvertedSection(template[idx..section_end], data, writer, tag_name);
                    idx = section_end;
                },
                .end_section => return,

                .comment => {},
                .set_delim => {
                    comptime const start_end = std.mem.indexOfAny(u8, tag_name, " \t\n") orelse {
                        @compileError("Syntax error: missing whitespace between delimiters in set delimiter tag ");
                    };
                    comptime const end_start = std.mem.lastIndexOfAny(u8, tag_name, " \t\n") orelse unreachable;
                    self.delim_start = tag_name[0..start_end];
                    self.delim_end = tag_name[end_start + 1 ..];
                },

                .partial => @compileError("Partials are not supported"),
            }
        }
    }

    fn renderSection(
        comptime self: *Renderer,
        comptime template: []const u8,
        data: anytype,
        writer: anytype,
        comptime tag_name: []const u8,
    ) !void {
        const section_data = truthyValue(getField(data, tag_name)) orelse return;
        const T = @TypeOf(section_data);
        if (T == bool) {
            try self.renderInternal(template, data, writer, tag_name);
        } else if (comptime std.meta.trait.isIndexable(T)) {
            comptime var i = 0;
            for (section_data) |entry| {
                try self.renderInternal(template, entry, writer, tag_name);
            }
        } else {
            try self.renderInternal(template, section_data, writer, tag_name);
        }
        // TODO: lambdas
    }

    fn renderInvertedSection(
        comptime self: *Renderer,
        comptime template: []const u8,
        data: anytype,
        writer: anytype,
        comptime tag_name: []const u8,
    ) !void {
        if (truthyValue(getField(data, tag_name))) |_| return;
        try self.renderInternal(template, data, writer, tag_name);
    }

    fn findEndTag(
        comptime self: *Renderer,
        comptime template: []const u8,
        comptime start_idx: usize,
        comptime expected_name: []const u8,
    ) usize {
        comptime var idx = start_idx;
        comptime var level = 0;
        inline while (true) {
            // Find the next tag
            comptime var start = std.mem.indexOfPos(u8, template, idx, self.delim_start) orelse {
                @compileError("Unmatched section tag '" ++ expected_name ++ "'.");
            };
            start += self.delim_start.len;

            // Find the end of the tag
            comptime const end = std.mem.indexOfPos(u8, template, start, self.delim_end) orelse {
                @compileError("Syntax error: missing end delimiter");
            };
            idx = end + self.delim_end.len;

            switch (template[start]) {
                '#', '^' => level += 1,
                '/' => if (level == 0) {
                    if (comptime !std.mem.eql(u8, expected_name, template[start + 1 .. end])) {
                        @compileError("Unexpected closing tag '" ++ tag_name ++ "', expected '" ++ expected_name ++ "'.");
                    }
                    return idx;
                } else {
                    level -= 1;
                },
                '=' => unreachable,
                else => {},
            }
        }
    }

    fn getField(data: anytype, comptime tag_name: []const u8) GetField(@TypeOf(data), tag_name) {
        if (comptime std.mem.indexOf(u8, tag_name, ".")) |idx| {
            return getField(@field(data, tag_name[0..idx]), tag_name[idx + 1 ..]);
        } else {
            return @field(data, tag_name);
        }
    }
    fn GetField(comptime T: type, comptime tag_name: []const u8) type {
        var Ty = T;
        var iter = std.mem.tokenize(tag_name, ".");
        while (iter.next()) |field_name| {
            Ty = @TypeOf(@field(@as(Ty, undefined), field_name));
        }
        return Ty;
    }
};

const StackEntry = struct { name: []const u8, data: anytype };
const TagType = enum {
    variable,
    unescaped,
    section,
    end_section,
    inverted,
    comment,
    partial,
    set_delim,
};

test "variables: simple names" {
    const result = try render(std.testing.allocator,
        \\* {{name}}
        \\* {{age}}
        \\* {{company}}
        \\* {{{company}}}
    , .{
        .name = "Chris",
        .company = "<b>GitHub</b>",
        .age = @as(?u32, null),
    });
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(
        \\* Chris
        \\* 
        \\* &lt;b&gt;GitHub&lt;/b&gt;
        \\* <b>GitHub</b>
    , result);
}

test "variables: nested names" {
    const result = try render(std.testing.allocator,
        \\{{person.name}}
    , .{
        .person = .{ .name = "Chris" },
    });
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(
        \\Chris
    , result);
}

test "sections: false value" {
    const result = try render(std.testing.allocator,
        \\Shown.
        \\{{#person}}
        \\  Never shown!
        \\{{/person}}
    , .{ .person = false });
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(
        \\Shown.
        \\
    , result);
}

test "sections: non-empty list" {
    const result = try render(std.testing.allocator,
        \\{{#repo}}
        \\  <b>{{name}}</b>
        \\{{/repo}}
    , .{ .repo = &[_]Repo{
        .{ .name = "resque" },
        .{ .name = "hub" },
        .{ .name = "rib" },
    } });
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(
        \\
        \\  <b>resque</b>
        \\
        \\  <b>hub</b>
        \\
        \\  <b>rib</b>
        \\
    , result);
}
const Repo = struct { name: []const u8 };

test "sections: non-false value" {
    const result = try render(std.testing.allocator,
        \\{{#person}}
        \\  Hi {{name}}!
        \\{{/person}}
    , .{ .person = .{ .name = "Jon" } });
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(
        \\
        \\  Hi Jon!
        \\
    , result);
}

test "inverted sections" {
    const result = try render(std.testing.allocator,
        \\{{#repo}}
        \\  <b>{{name}}</b>
        \\{{/repo}}
        \\{{^repo}}
        \\  No repos :(
        \\{{/repo}}
    , .{ .repo = &[_]Repo{} });
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(
        \\
        \\
        \\  No repos :(
        \\
    , result);
}

test "comments" {
    const result = try render(std.testing.allocator,
        \\<h1>Today{{! ignore me }}.</h1>
    , .{ .repo = &[_]Repo{} });
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(
        \\<h1>Today.</h1>
    , result);
}

test "set delimiter" {
    const result = try render(std.testing.allocator,
        \\* {{default_tags}}
        \\{{=<% %>=}}
        \\* <% erb_style_tags %>
        \\<%={{ }}=%>
        \\* {{default_tags_again}}
    , .{
        .default_tags = "default tags",
        .erb_style_tags = "erb-style tags",
        .default_tags_again = "default tags again",
    });
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(
        \\* default tags
        \\
        \\* erb-style tags
        \\
        \\* default tags again
    , result);
}

fn writeValue(writer: anytype, value: anytype) !void {
    const v = unwrapOptional(value) orelse return;
    if (@TypeOf(v) == void) {
        return;
    } else if (comptime std.meta.trait.isZigString(@TypeOf(v))) {
        try writeEscaped(writer, v);
    } else {
        try writer.print("{}", .{v});
    }
}

fn writeEscaped(writer: anytype, s: []const u8) !void {
    var idx: usize = 0;
    while (true) {
        const next = std.mem.indexOfAnyPos(u8, s, idx, "<>&'\"") orelse {
            try writer.writeAll(s[idx..]);
            return;
        };
        try writer.writeAll(s[idx..next]);

        const escaped = switch (s[next]) {
            '<' => "&lt;",
            '>' => "&gt;",
            '&' => "&amp;",
            '\'' => "&#39;", // Shorter than &apos;
            '"' => "&#34;", // Shorter than &quot;
            else => unreachable,
        };
        try writer.writeAll(escaped);

        idx = next + 1;
    }
}

fn writeValueUnescaped(writer: anytype, value: anytype) !void {
    const v = unwrapOptional(value) orelse return;
    if (@TypeOf(v) == void) {
        return;
    } else if (comptime std.meta.trait.isZigString(@TypeOf(v))) {
        try writer.writeAll(v);
    } else {
        try writer.print("{}", .{v});
    }
}

fn unwrapOptional(value: anytype) ?UnwrapOptional(@TypeOf(value)) {
    return value;
}
fn UnwrapOptional(comptime T: type) type {
    if (@typeInfo(T) == .Optional) {
        return std.meta.Child(T);
    } else {
        return T;
    }
}

fn truthyValue(value: anytype) ?UnwrapOptional(@TypeOf(value)) {
    const v = unwrapOptional(value) orelse return null;
    const T = @TypeOf(v);

    if (T == bool) {
        if (!v) return null;
    } else if (comptime std.meta.trait.isIndexable(T)) {
        if (v.len == 0) return null;
    } else {
        return v;
    }

    return v;
}
