//! Generate a deterministic large XML benchmark input.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse "svg-large.xml";
    const target_bytes: usize = 16 * 1024 * 1024;

    var allocating: std.Io.Writer.Allocating = .init(init.gpa);
    defer allocating.deinit();
    const writer = &allocating.writer;

    try writer.writeAll(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4096\" height=\"4096\" viewBox=\"0 0 4096 4096\">\n",
    );

    var index: usize = 0;
    while (allocating.writer.end < target_bytes) : (index += 1) {
        try writer.print(
            "  <g id=\"layer{d}\" transform=\"translate({d}.5 {d}.25)\" fill=\"#{x:0>6}\">\n",
            .{ index, index % 97, index % 89, (index * 2654435761) & 0xFFFFFF },
        );
        for (0..8) |shape| {
            const x = (index * 13 + shape * 7) % 4000;
            const y = (index * 17 + shape * 11) % 4000;
            try writer.print(
                "    <rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"#{x:0>6}\" stroke=\"#{x:0>6}\" stroke-width=\"{d}.5\"/>\n",
                .{
                    x,
                    y,
                    10 + shape,
                    20 + shape,
                    (x * 2246822519) & 0xFFFFFF,
                    (y * 3266489917) & 0xFFFFFF,
                    shape,
                },
            );
        }
        try writer.print(
            "    <text x=\"{d}\" y=\"{d}\" font-size=\"12\">label {d} &amp; value &lt;{d}&gt;</text>\n",
            .{ index % 4000, (index * 3) % 4000, index, index * 7 },
        );
        try writer.writeAll("  </g>\n");
    }
    try writer.writeAll("</svg>\n");

    const data = try allocating.toOwnedSlice();
    defer init.gpa.free(data);
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = path,
        .data = data,
    });
    std.debug.print("generated {s}: {d} bytes\n", .{ path, data.len });
}
