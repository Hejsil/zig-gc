const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const debug = std.debug;

pub const GcAllocator = struct {
    const PointerList = std.SegmentedList(Pointer, 0);

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

    pub fn init(child_alloc: *mem.Allocator, start: *const u8) GcAllocator {
        return GcAllocator{
            .base = mem.Allocator{
                .allocFn = alloc,
                .reallocFn = realloc,
                .freeFn = free,
            },
            .start = @ptrCast([*]const u8, start),
            .ptrs = PointerList.init(child_alloc),
        };
    }

    pub fn deinit(gc: *GcAllocator) void {
        const child_alloc = gc.childAllocator();

        var iter = gc.ptrs.iterator(0);
        while (iter.next()) |ptr| {
            child_alloc.free(ptr.memory);
        }

        gc.ptrs.deinit();
        gc.* = undefined;
    }

    pub fn collect(gc: *GcAllocator) void {
        const frame = blk: {
            const end = @ptrCast([*]const u8, @frameAddress());
            const i_start = @ptrToInt(gc.start);
            const i_end = @ptrToInt(end);
            if (i_start < i_end)
                break :blk gc.start[0 .. i_end - i_start];

            break :blk end[0 .. i_start - i_end];
        };
        gc.collectFrame(frame);
    }

    pub fn collectFrame(gc: *GcAllocator, frame: []const u8) void {
        gc.mark(frame);
        gc.sweep();
    }

    pub fn allocator(gc: *GcAllocator) *mem.Allocator {
        return &gc.base;
    }

    fn mark(gc: *GcAllocator, frame: []const u8) void {
        for (frame) |*byte| {
            // TODO: This is a really ugly cast. Will pointer ever be stored unaligned?
            //       I guess they could be in packed structs, but is that even allowed?
            //       If ptrs are always aligned, we can skip every @alignOf(*u8) bytes.
            const Ptr = *align(@alignOf(u8)) const [*]u8;
            const frame_ptr = @ptrCast(Ptr, byte);
            const ptr = gc.findPtr(frame_ptr.*) orelse continue;
            if (ptr.flags.checked)
                continue;

            ptr.flags.marked = true;
            ptr.flags.checked = true;
            gc.mark(ptr.memory);
        }
    }

    fn sweep(gc: *GcAllocator) void {
        const child_alloc = gc.childAllocator();
        var i: usize = 0;
        while (i < gc.ptrs.len) {
            const ptr = gc.ptrs.at(i);
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

        var iter = gc.ptrs.iterator(0);
        while (iter.next()) |ptr| {
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
        ptr.* = gc.ptrs.pop() orelse undefined;
    }

    fn childAllocator(gc: *GcAllocator) *mem.Allocator {
        return gc.ptrs.allocator;
    }

    fn alloc(base: *mem.Allocator, n: usize, alignment: u29) ![]u8 {
        const gc = @fieldParentPtr(GcAllocator, "base", base);
        const child_alloc = gc.childAllocator();
        const memory = try child_alloc.allocFn(child_alloc, n, alignment);
        try gc.ptrs.push(Pointer{
            .flags = Flags.zero,
            .memory = memory,
        });

        return memory;
    }

    fn realloc(base: *mem.Allocator, old_mem: []u8, new_size: usize, alignment: u29) ![]u8 {
        if (new_size <= old_mem.len) {
            return old_mem[0..new_size];
        } else {
            const result = try alloc(base, new_size, alignment);
            mem.copy(u8, result, old_mem);
            return result;
        }
    }

    fn free(base: *mem.Allocator, bytes: []u8) void {
        const gc = @fieldParentPtr(GcAllocator, "base", base);
        const child_alloc = gc.childAllocator();
        const ptr = gc.findPtr(bytes.ptr) orelse @panic("Freeing memory not allocated by garbage collector!");
        gc.freePtr(ptr);
    }
};

const Leaker = struct {
    l: *Leaker,
};

test "gc.collect: No leaks" {
    var gc = GcAllocator.init(debug.global_allocator, @frameAddress());
    defer gc.deinit();
    const allocator = gc.allocator();

    var a = try allocator.create(Leaker{ .l = try allocator.create(Leaker(undefined)) });
    a.l.l = a;
    gc.collect();

    debug.assert(gc.findPtr(a) != null);
    debug.assert(gc.findPtr(a.l) != null);
    debug.assert(gc.ptrs.len == 2);
}

fn leak(allocator: *mem.Allocator) !void {
    var a = try allocator.create(Leaker{ .l = try allocator.create(Leaker(undefined)) });
    a.l.l = a;
}

test "gc.collect: Leaks" {
    var gc = GcAllocator.init(debug.global_allocator, @frameAddress());
    defer gc.deinit();
    const allocator = gc.allocator();

    var a = try allocator.create(Leaker{ .l = try allocator.create(Leaker(undefined)) });
    a.l.l = a;
    try leak(allocator);
    gc.collect();

    debug.assert(gc.findPtr(a) != null);
    debug.assert(gc.findPtr(a.l) != null);
    debug.assert(gc.ptrs.len == 2);
}

test "gc.free" {
    var gc = GcAllocator.init(debug.global_allocator, @frameAddress());
    defer gc.deinit();
    const allocator = gc.allocator();

    var a = try allocator.create(Leaker(undefined));
    var b = try allocator.create(Leaker(undefined));
    allocator.destroy(b);

    debug.assert(gc.findPtr(a) != null);
    debug.assert(gc.ptrs.len == 1);
}
