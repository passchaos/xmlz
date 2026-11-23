//! Small byte-copy helpers shared by the writer and tree builders.

/// Copy `in` into `out`, which must have the same length. Spans shorter than
/// sixteen bytes use two overlapping width-appropriate loads and stores; the
/// size dispatch in `memcpy` costs more than the copy for the few-byte fields
/// that dominate markup.
pub inline fn copyShort(out: []u8, in: []const u8) void {
    const n = in.len;
    if (n >= 16) {
        @memcpy(out[0..n], in);
        return;
    }
    if (n >= 8) {
        out[0..8].* = in[0..8].*;
        out[n - 8 ..][0..8].* = in[n - 8 ..][0..8].*;
        return;
    }
    if (n >= 4) {
        out[0..4].* = in[0..4].*;
        out[n - 4 ..][0..4].* = in[n - 4 ..][0..4].*;
        return;
    }
    if (n >= 2) {
        out[0..2].* = in[0..2].*;
        out[n - 2 ..][0..2].* = in[n - 2 ..][0..2].*;
        return;
    }
    if (n == 1) out[0] = in[0];
}
