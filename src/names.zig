//! Name comparison shared by the XPath and XSLT engines.

const std = @import("std");

/// Compare names without an out-of-line call. XML names are usually short,
/// and `std.mem.eql` is shared by enough call sites that the compiler keeps
/// it out of line; inlining the short cases saves the call overhead.
pub inline fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.len == 0 or a.ptr == b.ptr) return true;
    if (a.len < 4) {
        const x = (a[0] ^ b[0]) | (a[a.len - 1] ^ b[a.len - 1]) |
            (a[a.len / 2] ^ b[a.len / 2]);
        return x == 0;
    }
    if (a.len <= 16) {
        var x: u32 = 0;
        for ([_]usize{ 0, a.len - 4, (a.len / 8) * 4, a.len - 4 - ((a.len / 8) * 4) }) |n| {
            x |= @as(u32, @bitCast(a[n..][0..4].*)) ^
                @as(u32, @bitCast(b[n..][0..4].*));
        }
        return x == 0;
    }
    return std.mem.eql(u8, a, b);
}
