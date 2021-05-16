const std = @import("std");
const mustache = @import("mustache.zig");

const Data = struct {
    name: []const u8,
    messages: []const Message,
};
const Message = struct {
    subject: []const u8,
};

pub fn main() !void {
    const template_data = Data{
        .name = "Bob",
        .messages = &.{
            .{ .subject = "How was your day today?" },
            .{ .subject = "Helo I am the 9th prince of Nigeria" },
            .{ .subject = "Order confirmed: your tightrope will be delivered on the..." },
        },
    };
    try mustache.renderTo(
        \\Hello, {{name}}!
        \\You have {{messages.len}} new messages:
        \\{{#messages}}
        \\ - {{subject}}
        \\{{/messages}}
        \\{{^messages}}
        \\   {{! no messages, how sad }}
        \\   Nothing here :(
        \\{{/messages}}
    , template_data, std.io.getStdOut().writer());
}
