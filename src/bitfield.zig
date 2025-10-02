const std = @import("std");

const BitfieldErr = error{ InconsistentLineLength, UnexpectedCharacter };

const Bitfield = struct {
    width: usize,
    height: usize,
    data: []Elem,

    const Elem = u64;
    const elem_bit_width: usize = @sizeOf(Elem) * 8;
    const max_elem: Elem = std.math.maxInt(Elem);

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Bitfield {
        const data = try allocator.alloc(Elem, std.math.divCeil(u64, width * height, elem_bit_width));
        @memset(data, 0);
        return Bitfield{
            .width = width,
            .height = height,
            .data = data,
        };
    }

    pub fn deinit(self: Bitfield, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    const FromStringConfig = struct {
        char0: u8 = '0',
        char1: u8 = '1',
    };

    /// Init the bitfield from a string representation.
    /// Returns an error if the lines are not all the same length, except for lines of
    /// length 0 which are skipped.
    pub fn initFromString(allocator: std.mem.Allocator, str: []const u8, config: FromStringConfig) !Bitfield {
        var width: usize = 0;
        var height: usize = 0;
        // ArrayList as temporary storage
        var tmp = try std.ArrayList(Elem).initCapacity(allocator, 1);
        defer tmp.deinit(allocator);

        var buf: Elem = 0;
        var bits_copied: usize = 0;

        var iter = std.mem.tokenizeScalar(u8, str, '\n');
        while (iter.next()) |line| {
            if (line.len == 0) {
                continue;
            }
            height += 1;
            if (width == 0) {
                width = line.len;
            } else if (width != line.len) {
                return BitfieldErr.InconsistentLineLength;
            }
            for (line) |char| {
                buf = buf << 1;
                if (char == config.char1) {
                    buf = buf | 1;
                } else if (char != config.char0) {
                    return BitfieldErr.UnexpectedCharacter;
                }
                bits_copied += 1;
                if (bits_copied == elem_bit_width) {
                    try tmp.append(allocator, buf);
                    bits_copied = 0;
                    buf = 0;
                }
            }
        }
        if (bits_copied > 0) {
            try tmp.append(allocator, buf << @intCast(elem_bit_width - bits_copied));
        }
        return Bitfield{
            .width = width,
            .height = height,
            .data = try tmp.toOwnedSlice(allocator),
        };
    }
};

test "From string simple" {
    const s =
        \\010
        \\001
        \\100
    ;
    const data = [_]Bitfield.Elem{0b0100011000000000000000000000000000000000000000000000000000000000};

    const allocator = std.testing.allocator;
    const b = try Bitfield.initFromString(allocator, s, .{});
    defer b.deinit(allocator);
    try std.testing.expectEqualSlices(Bitfield.Elem, &data, b.data);
    try std.testing.expectEqual(3, b.width);
    try std.testing.expectEqual(3, b.height);
}

test "From string 64 wide" {
    const s =
        \\0100000000000000000000000000000000000000000000000000000000000000
        \\0010000000000000000000000000000000000000000000000000000000000000
        \\1000000000000000000000000000000000000000000000000000000000000000
    ;
    const data = [_]Bitfield.Elem{
        0b0100000000000000000000000000000000000000000000000000000000000000,
        0b0010000000000000000000000000000000000000000000000000000000000000,
        0b1000000000000000000000000000000000000000000000000000000000000000,
    };

    const allocator = std.testing.allocator;
    const b = try Bitfield.initFromString(allocator, s, .{});
    defer b.deinit(allocator);
    try std.testing.expectEqualSlices(Bitfield.Elem, &data, b.data);
    try std.testing.expectEqual(64, b.width);
    try std.testing.expectEqual(3, b.height);
}

test "From string wider" {
    const s =
        \\010000000000000000000000000000000000000000000000000000000000000000
        \\001000000000000000000000000000000000000000000000000000000000000000
        \\100000000000000000000000000000000000000000000000000000000000000000
    ;
    const data = [_]Bitfield.Elem{
        0b0100000000000000000000000000000000000000000000000000000000000000,
        0b0000100000000000000000000000000000000000000000000000000000000000,
        0b0000100000000000000000000000000000000000000000000000000000000000,
        0b0000000000000000000000000000000000000000000000000000000000000000,
    };

    const allocator = std.testing.allocator;
    const b = try Bitfield.initFromString(allocator, s, .{});
    defer b.deinit(allocator);
    try std.testing.expectEqualSlices(Bitfield.Elem, &data, b.data);
    try std.testing.expectEqual(66, b.width);
    try std.testing.expectEqual(3, b.height);
}
