const bench = @import("bench");
const builtin = @import("builtin");
const std = @import("std");

const heap = std.heap;
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;

pub const GcAllocator = struct {
    const PointerList = std.ArrayList(Pointer);

    base: mem.Allocator,
    start: [*]const u8,
    ptrs: PointerList,

    const Flags = packed struct {
        checked: bool,
        marked: bool,

        const zero = Flags{
            .checked = false,
            .marked = false,
        };
    };

    const Pointer = struct {
        flags: Flags,
        memory: []u8,
    };

    pub inline fn init(child_alloc: *mem.Allocator) GcAllocator {
        return GcAllocator{
            .base = mem.Allocator{
                .reallocFn = realloc,
                .shrinkFn = shrink,
            },
            .start = @intToPtr([*]const u8, @frameAddress()),
            .ptrs = PointerList.init(child_alloc),
        };
    }

    pub fn deinit(gc: *GcAllocator) void {
        const child_alloc = gc.childAllocator();

        for (gc.ptrs.toSlice()) |ptr| {
            child_alloc.free(ptr.memory);
        }

        gc.ptrs.deinit();
        gc.* = undefined;
    }

    pub fn collect(gc: *GcAllocator) void {
        @noInlineCall(collectNoInline, gc);
    }

    pub fn collectFrame(gc: *GcAllocator, frame: []const u8) void {
        gc.mark(frame);
        gc.sweep();
    }

    pub fn allocator(gc: *GcAllocator) *mem.Allocator {
        return &gc.base;
    }

    fn collectNoInline(gc: *GcAllocator) void {
        const frame = blk: {
            const end = @intToPtr([*]const u8, @frameAddress());
            const i_start = @ptrToInt(gc.start);
            const i_end = @ptrToInt(end);
            if (i_start < i_end)
                break :blk gc.start[0 .. i_end - i_start];

            break :blk end[0 .. i_start - i_end];
        };
        gc.collectFrame(frame);
    }

    fn mark(gc: *GcAllocator, frame: []const u8) void {
        const ptr_size = @sizeOf(*u8);
        for ([_]void{{}} ** ptr_size) |_, i| {
            if (frame.len <= i)
                break;

            const frame2 = frame[i..];
            const len = (frame2.len / ptr_size) * ptr_size;
            for (@bytesToSlice([*]u8, frame2[0..len])) |frame_ptr| {
                const ptr = gc.findPtr(frame_ptr) orelse continue;
                if (ptr.flags.checked)
                    continue;

                ptr.flags.marked = true;
                ptr.flags.checked = true;
                gc.mark(ptr.memory);
            }
        }
    }

    fn sweep(gc: *GcAllocator) void {
        const child_alloc = gc.childAllocator();
        const ptrs = gc.ptrs.toSlice();
        var i: usize = 0;
        while (i < gc.ptrs.len) {
            const ptr = &ptrs[i];
            if (ptr.flags.marked) {
                ptr.flags = Flags.zero;
                i += 1;
                continue;
            }

            gc.freePtr(ptr);
        }
    }

    fn findPtr(gc: *GcAllocator, to_find_ptr: var) ?*Pointer {
        comptime debug.assert(@typeInfo(@typeOf(to_find_ptr)) == builtin.TypeId.Pointer);

        for (gc.ptrs.toSlice()) |*ptr| {
            const ptr_start = @ptrToInt(ptr.memory.ptr);
            const ptr_end = ptr_start + ptr.memory.len;
            if (ptr_start <= @ptrToInt(to_find_ptr) and @ptrToInt(to_find_ptr) < ptr_end)
                return ptr;
        }

        return null;
    }

    fn freePtr(gc: *GcAllocator, ptr: *Pointer) void {
        const child_alloc = gc.childAllocator();
        child_alloc.free(ptr.memory);

        // Swap the just freed pointer with the last pointer in the list.
        ptr.* = undefined;
        ptr.* = gc.ptrs.popOrNull() orelse undefined;
    }

    fn childAllocator(gc: *GcAllocator) *mem.Allocator {
        return gc.ptrs.allocator;
    }

    fn alloc(base: *mem.Allocator, n: usize, alignment: u29) ![]u8 {
        const gc = @fieldParentPtr(GcAllocator, "base", base);
        const child_alloc = gc.childAllocator();
        const memory = try child_alloc.reallocFn(child_alloc, ([*]u8)(undefined)[0..0], 0, n, alignment);
        try gc.ptrs.append(Pointer{
            .flags = Flags.zero,
            .memory = memory,
        });

        return memory;
    }

    fn free(base: *mem.Allocator, bytes: []u8) void {
        const gc = @fieldParentPtr(GcAllocator, "base", base);
        const child_alloc = gc.childAllocator();
        const ptr = gc.findPtr(bytes.ptr) orelse @panic("Freeing memory not allocated by garbage collector!");
        gc.freePtr(ptr);
    }

    fn realloc(base: *mem.Allocator, old_mem: []u8, old_alignment: u29, new_size: usize, alignment: u29) mem.Allocator.Error![]u8 {
        if (new_size == 0) {
            free(base, old_mem);
            return ([*]u8)(undefined)[0..0];
        } else if (new_size <= old_mem.len) {
            return old_mem[0..new_size];
        } else {
            const result = try alloc(base, new_size, alignment);
            mem.copy(u8, result, old_mem);
            return result;
        }
    }

    fn shrink(base: *mem.Allocator, old_mem: []u8, old_alignment: u29, new_size: usize, alignment: u29) []u8 {
        if (new_size == 0) {
            free(base, old_mem);
            return ([*]u8)(undefined)[0..0];
        } else if (new_size <= old_mem.len) {
            return old_mem[0..new_size];
        } else {
            unreachable;
        }
    }
};

const Leaker = struct {
    l: *Leaker,
};

var test_buf: [1024 * 1024]u8 = undefined;

test "gc.collect: No leaks" {
    var fba = heap.FixedBufferAllocator.init(test_buf[0..]);
    var gc = GcAllocator.init(&fba.allocator);
    defer gc.deinit();

    const allocator = gc.allocator();

    var a = try allocator.create(Leaker);
    a.* = Leaker{ .l = try allocator.create(Leaker) };
    a.l.l = a;
    gc.collect();

    testing.expect(gc.findPtr(a) != null);
    testing.expect(gc.findPtr(a.l) != null);
    testing.expectEqual(usize(2), gc.ptrs.len);
}

fn leak(allocator: *mem.Allocator) !void {
    var a = try allocator.create(Leaker);
    a.* = Leaker{ .l = try allocator.create(Leaker) };
    a.l.l = a;
}

test "gc.collect: Leaks" {
    var fba = heap.FixedBufferAllocator.init(test_buf[0..]);
    var gc = GcAllocator.init(&fba.allocator);
    defer gc.deinit();

    const allocator = gc.allocator();

    var a = try allocator.create(Leaker);
    a.* = Leaker{ .l = try allocator.create(Leaker) };
    a.l.l = a;
    try @noInlineCall(leak, allocator);
    gc.collect();

    testing.expect(gc.findPtr(a) != null);
    testing.expect(gc.findPtr(a.l) != null);
    testing.expectEqual(usize(2), gc.ptrs.len);
}

test "gc.free" {
    var fba = heap.FixedBufferAllocator.init(test_buf[0..]);
    var gc = GcAllocator.init(&fba.allocator);
    defer gc.deinit();

    const allocator = gc.allocator();

    var a = try allocator.create(Leaker);
    var b = try allocator.create(Leaker);
    allocator.destroy(b);

    testing.expect(gc.findPtr(a) != null);
    testing.expectEqual(usize(1), gc.ptrs.len);
}

test "gc.benchmark" {
    try bench.benchmark(struct {
        const Arg = struct {
            num: usize,
            size: usize,

            fn benchAllocator(a: Arg, allocator: *mem.Allocator, comptime free: bool) !void {
                var i: usize = 0;
                while (i < a.num) : (i += 1) {
                    const bytes = try allocator.alloc(u8, a.size);
                    defer if (free) allocator.free(bytes);
                }
            }
        };

        pub const args = [_]Arg{
            Arg{ .num = 10 * 1, .size = 1024 * 1 },
            Arg{ .num = 10 * 2, .size = 1024 * 1 },
            Arg{ .num = 10 * 4, .size = 1024 * 1 },
            Arg{ .num = 10 * 1, .size = 1024 * 2 },
            Arg{ .num = 10 * 2, .size = 1024 * 2 },
            Arg{ .num = 10 * 4, .size = 1024 * 2 },
            Arg{ .num = 10 * 1, .size = 1024 * 4 },
            Arg{ .num = 10 * 2, .size = 1024 * 4 },
            Arg{ .num = 10 * 4, .size = 1024 * 4 },
        };

        pub const iterations = 10000;

        pub fn FixedBufferAllocator(a: Arg) void {
            var fba = heap.FixedBufferAllocator.init(test_buf[0..]);
            a.benchAllocator(&fba.allocator, false) catch unreachable;
        }

        pub fn Arena_FixedBufferAllocator(a: Arg) void {
            var fba = heap.FixedBufferAllocator.init(test_buf[0..]);
            var arena = heap.ArenaAllocator.init(&fba.allocator);
            defer arena.deinit();

            a.benchAllocator(&arena.allocator, false) catch unreachable;
        }

        pub fn GcAllocator_FixedBufferAllocator(a: Arg) void {
            var fba = heap.FixedBufferAllocator.init(test_buf[0..]);
            var gc = GcAllocator.init(&fba.allocator);
            defer gc.deinit();

            a.benchAllocator(gc.allocator(), false) catch unreachable;
            gc.collect();
        }

        pub fn DirectAllocator(a: Arg) void {
            var da = heap.DirectAllocator.init();
            defer da.deinit();

            a.benchAllocator(&da.allocator, true) catch unreachable;
        }

        pub fn Arena_DirectAllocator(a: Arg) void {
            var da = heap.DirectAllocator.init();
            defer da.deinit();

            var arena = heap.ArenaAllocator.init(&da.allocator);
            defer arena.deinit();

            a.benchAllocator(&arena.allocator, false) catch unreachable;
        }

        pub fn GcAllocator_DirectAllocator(a: Arg) void {
            var da = heap.DirectAllocator.init();
            defer da.deinit();

            var gc = GcAllocator.init(&da.allocator);
            defer gc.deinit();

            a.benchAllocator(gc.allocator(), false) catch unreachable;
            gc.collect();
        }
    });
}
