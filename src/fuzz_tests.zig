//! Deterministic mutation smoke tests for the parser, DOM, writer, and XPath.
//!
//! These are not coverage-guided fuzzers; they exercise deep parser paths by
//! mutating a corpus of valid and invalid documents. A panic, leak, or writer
//! round-trip failure is a test failure.

const std = @import("std");
const parser_mod = @import("parser.zig");
const dom = @import("dom.zig");
const writer = @import("writer.zig");
const xpath = @import("xpath/root.zig");

const seeds = [_][]const u8{
    "<a/>",
    "<?xml version=\"1.0\"?><root a=\"1\"><b>text&amp;more</b></root>",
    "<!DOCTYPE a [<!ENTITY e \"x\"><!ELEMENT a ANY><!ATTLIST a b CDATA \"v\">]><a>&e;</a>",
    "<a xmlns=\"urn:d\" xmlns:p=\"urn:p\"><p:b p:c=\"1\"/></a>",
    "<?xml version=\"1.1\"?><a>&#x1;&#x85;</a>",
    "<a><!-- c --><![CDATA[x<y]]><?pi d?></a>",
    "<!DOCTYPE a SYSTEM \"x.dtd\"><a/>",
    "<a b='1' c=\"2\">text</a>",
};

test "parser DOM writer and XPath survive mutated inputs" {
    var prng = std.Random.DefaultPrng.init(0x9e37_79b9_7f4a_7c15);
    const random = prng.random();
    var buffer: [2048]u8 = undefined;

    for (0..1000) |_| {
        const seed = seeds[random.uintLessThan(usize, seeds.len)];
        var len: usize = @min(seed.len, buffer.len);
        @memcpy(buffer[0..len], seed[0..len]);

        const mutation_count = random.uintLessThan(usize, 8) + 1;
        for (0..mutation_count) |_| {
            if (len == 0) break;
            switch (random.uintLessThan(u8, 5)) {
                0 => buffer[random.uintLessThan(usize, len)] = random.int(u8),
                1 => len = random.uintLessThan(usize, len),
                2 => {
                    if (len < buffer.len) {
                        const at = random.uintLessThan(usize, len + 1);
                        std.mem.copyBackwards(
                            u8,
                            buffer[at + 1 .. len + 1],
                            buffer[at..len],
                        );
                        const specials = "<>&;[]'\"=:/!?%# \t\r\n\x00\xFF";
                        buffer[at] = specials[
                            random.uintLessThan(
                                usize,
                                specials.len,
                            )
                        ];
                        len += 1;
                    }
                },
                3 => {
                    const at = random.uintLessThan(usize, len);
                    std.mem.copyForwards(
                        u8,
                        buffer[at .. len - 1],
                        buffer[at + 1 .. len],
                    );
                    len -= 1;
                },
                else => {
                    const at = random.uintLessThan(usize, len);
                    const shift: u3 = @intCast(random.uintLessThan(u4, 8));
                    buffer[at] ^= @as(u8, 1) << shift;
                },
            }
        }

        const input = buffer[0..len];
        {
            var parser = parser_mod.Parser.init(input, .{
                .allocator = std.testing.allocator,
                .namespaces = true,
            });
            defer parser.deinit();
            while (parser.next() catch break) |_| {}
        }

        var document = dom.Document.parse(std.testing.allocator, input, .{
            .keep_comments = true,
            .keep_pis = true,
        }) catch continue;
        defer document.deinit();

        var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer allocating.deinit();
        writer.writeDocument(&allocating.writer, &document, .{
            .xml_declaration = false,
        }) catch continue;
        const output = allocating.toOwnedSlice() catch continue;
        defer std.testing.allocator.free(output);

        {
            var reparsed = dom.Document.parse(
                std.testing.allocator,
                output,
                .{},
            ) catch return error.WriterProducedInvalidXml;
            defer reparsed.deinit();
        }

        const expressions = [_][]const u8{
            "//*",
            "//@*",
            "count(//node())",
            "string(/*)",
            "//*[1]",
        };
        var context: xpath.Context = .{
            .document = &document,
            .node = .{ .node = 0 },
        };
        for (expressions) |source| {
            var expression = xpath.Expression.parse(
                std.testing.allocator,
                source,
            ) catch continue;
            defer expression.deinit();
            var result = expression.evaluate(
                std.testing.allocator,
                &context,
            ) catch continue;
            result.deinit();
        }
    }
}
