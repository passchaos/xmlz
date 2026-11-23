//! Single-threaded bump allocator layered over a parent allocator.
//!
//! `std.heap.ArenaAllocator` is thread-safe and pays an atomic
//! read-modify-write on every allocation and an atomic load on every
//! resize. Transformations allocate tens of thousands of small node sets
//! and strings on one thread, so a plain bump pointer over large chunks is
//! measurably cheaper. Memory belongs to the parent allocator; there is no
//! `deinit`.

const std = @import("std");

pub const Arena = struct {
    child: std.mem.Allocator,
    buffer: []u8 = &.{},
    index: usize = 0,
    /// Size of the next bump chunk. Grows geometrically so the unused tail
    /// of each chunk stays a small fraction of the memory handed out.
    chunk_size: usize = 64 * 1024,
    max_chunk_size: usize = 512 * 1024,

    pub fn init(child: std.mem.Allocator) Arena {
        return .{ .child = child };
    }

    pub fn allocator(self: *Arena) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ra: usize,
    ) ?[*]u8 {
        const self: *Arena = @ptrCast(@alignCast(ctx));
        const alignment_bytes = alignment.toByteUnits();
        const base = @intFromPtr(self.buffer.ptr);
        const start = std.mem.alignForward(
            usize,
            base + self.index,
            alignment_bytes,
        );
        const offset = start - base;
        if (offset + len <= self.buffer.len) {
            self.index = offset + len;
            return @ptrFromInt(start);
        }
        return self.allocChunk(len, alignment_bytes, ra);
    }

    fn allocChunk(
        self: *Arena,
        len: usize,
        alignment_bytes: usize,
        ra: usize,
    ) ?[*]u8 {
        const alignment: std.mem.Alignment = .fromByteUnits(
            @max(alignment_bytes, @alignOf(usize)),
        );
        if (len > self.chunk_size) {
            // Large requests get a dedicated block so the unused tail of the
            // bump chunk stays available for later small allocations.
            return self.child.rawAlloc(len, alignment, ra);
        }
        const size = self.chunk_size;
        const chunk = self.child.rawAlloc(size, alignment, ra) orelse return null;
        self.buffer = chunk[0..size];
        self.index = len;
        // Grow geometrically so the tail abandoned per chunk stays a small
        // fraction of the memory handed out.
        self.chunk_size = @min(size * 2, self.max_chunk_size);
        return chunk;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        _ = alignment;
        _ = ra;
        const self: *Arena = @ptrCast(@alignCast(ctx));
        const base = @intFromPtr(self.buffer.ptr);
        const mem_start = @intFromPtr(memory.ptr);
        if (mem_start < base or mem_start > base + self.buffer.len or
            mem_start + memory.len != base + self.index)
        {
            // Not the most recent allocation: it can shrink in place but
            // cannot grow.
            return new_len <= memory.len;
        }
        if (mem_start + new_len <= base + self.buffer.len) {
            self.index = mem_start - base + new_len;
            return true;
        }
        return false;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ra))
            memory.ptr
        else
            null;
    }

    fn free(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ra: usize,
    ) void {
        _ = alignment;
        _ = ra;
        const self: *Arena = @ptrCast(@alignCast(ctx));
        const base = @intFromPtr(self.buffer.ptr);
        const mem_start = @intFromPtr(memory.ptr);
        if (mem_start >= base and mem_start <= base + self.buffer.len and
            mem_start + memory.len == base + self.index)
        {
            self.index = mem_start - base;
        }
    }
};

const testing = std.testing;

test "local arena allocates, grows, and reuses the last block" {
    var parent = std.heap.ArenaAllocator.init(testing.allocator);
    defer parent.deinit();
    var arena: Arena = .init(parent.allocator());
    const allocator = arena.allocator();

    const first = try allocator.alloc(u8, 3);
    @memset(first, 7);
    try testing.expectEqual(@as(usize, 3), first.len);

    // Growing the last allocation stays in place.
    const grown = try allocator.realloc(first, 100);
    @memset(grown, 9);
    try testing.expectEqual(@as(usize, 100), grown.len);
    try testing.expectEqual(@as(u8, 9), grown[99]);

    // Shrinking a non-last allocation is accepted without moving.
    const second = try allocator.alloc(u32, 4);
    second[3] = 0xdeadbeef;
    const shrunk = try allocator.realloc(grown, 2);
    try testing.expectEqual(@as(usize, 2), shrunk.len);
    try testing.expectEqual(@as(u32, 0xdeadbeef), second[3]);

    // Large allocations get their own chunk without disturbing the bump
    // chunk that is still in use.
    const buffer_before = arena.buffer.ptr;
    const index_before = arena.index;
    const big = try allocator.alloc(u8, 200 * 1024);
    @memset(big, 1);
    try testing.expectEqual(@as(u8, 1), big[199 * 1024]);
    try testing.expectEqual(buffer_before, arena.buffer.ptr);
    try testing.expectEqual(index_before, arena.index);
    const after_big = try allocator.alloc(u8, 8);
    @memset(after_big, 2);
    try testing.expectEqual(buffer_before, arena.buffer.ptr);

    // Alignment requests are honored across the bump pointer.
    const aligned = try allocator.alignedAlloc(u8, .@"64", 16);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(aligned.ptr) % 64);
}
