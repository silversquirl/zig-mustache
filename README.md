# Zig Mustache

Mustache templates at comptime!

## Usage

```zig
// Render an inline template to an allocated []u8
const result = try mustache.render(allocator,
	\\Hello, {{name}}!
	\\You have {{messages.len}} new messages:
	\\{{#messages}}
	\\ - {{subject}}
	\\{{/messages}}
	\\{{^messages}}
	\\   {{! no messages, how sad }}
	\\   Nothing here :(
	\\{{/messages}}
, template_data);

// Render a template stored in a file to stdout
try mustache.renderTo(
	@embedFile("template.mustache"),
	template_data,
	std.io.getStdOut().writer()
);
```
