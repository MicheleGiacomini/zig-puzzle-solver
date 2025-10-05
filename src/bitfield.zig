const std = @import("std");

pub const BitfieldErr = error{ InconsistentLineLength, UnexpectedCharacter, FromatError, InsertCollision, RemoveMismatch };

pub const Bitfield = struct {
    width: usize,
    height: usize,
    data: []Elem,

    pub const Elem = u64;
    pub const elem_bit_width: usize = @sizeOf(Elem) * 8;
    pub const max_elem: Elem = std.math.maxInt(Elem);

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Bitfield {
        const size = std.math.divCeil(usize, width * height, elem_bit_width) catch unreachable;
        const data = try allocator.alloc(Elem, size);
        @memset(data, 0);
        return Bitfield{
            .width = width,
            .height = height,
            .data = data,
        };
    }

    pub fn deinit(self: *Bitfield, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    pub const FromStringConfig = struct {
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

    const F = struct {
        char0: u8 = '0',
        char1: u8 = '1',
        bf: *const Bitfield,

        pub fn format(self: F, writer: *std.Io.Writer) !void {
            var line_position: usize = 0;
            var height_position: usize = 0;
            const leftmost_bit: Elem = 1 << @intCast(elem_bit_width - 1);
            outer: for (self.bf.data) |current| {
                var elem = current;
                var index: usize = 0;
                while (index < elem_bit_width) : (index += 1) {
                    if (line_position == self.bf.width) {
                        height_position += 1;
                        if (height_position == self.bf.height) {
                            break :outer;
                        }
                        try writer.print("{s}", .{"\n"});
                        line_position = 0;
                    }
                    const next_char =
                        if (elem & leftmost_bit > 0) self.char1 else self.char0;
                    try writer.print("{c}", .{next_char});
                    elem = elem << 1;
                    line_position += 1;
                }
            }
        }
    };

    pub fn formatCustom(self: *const Bitfield, char0: u8, char1: u8) std.fmt.Alt(F, F.format) {
        return .{ .data = .{
            .char0 = char0,
            .char1 = char1,
            .bf = self,
        } };
    }

    pub fn format(
        self: *const Bitfield,
        writer: anytype,
    ) !void {
        const f = F{ .bf = self };
        return f.format(writer);
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

test "From string - toString simple" {
    const s =
        \\010
        \\001
        \\100
    ;

    const allocator = std.testing.allocator;
    const b = try Bitfield.initFromString(allocator, s, .{});
    defer b.deinit(allocator);
    const to_s = try std.fmt.allocPrint(allocator, "{f}", .{b});
    defer allocator.free(to_s);
    try std.testing.expectEqualStrings(s, to_s);
}

test "From string - toString 64 wide" {
    const s =
        \\0100000000000000000000000000000000000000000000000000000000000000
        \\0010000000000000000000000000000000000000000000000000000000000000
        \\1000000000000000000000000000000000000000000000000000000000000000
    ;
    const allocator = std.testing.allocator;
    const b = try Bitfield.initFromString(allocator, s, .{});
    defer b.deinit(allocator);
    const to_s = try std.fmt.allocPrint(allocator, "{f}", .{b});
    defer allocator.free(to_s);
    try std.testing.expectEqualStrings(s, to_s);
}

test "From string - toString wider" {
    const s =
        \\010000000000000000000000000000000000000000000000000000000000000000
        \\001000000000000000000000000000000000000000000000000000000000000000
        \\100000000000000000000000000000000000000000000000000000000000000000
    ;
    const allocator = std.testing.allocator;
    const b = try Bitfield.initFromString(allocator, s, .{});
    defer b.deinit(allocator);
    const to_s = try std.fmt.allocPrint(allocator, "{f}", .{b});
    defer allocator.free(to_s);
    try std.testing.expectEqualStrings(s, to_s);
}

test "From string - toString custom" {
    const s =
        \\ # 
        \\  #
        \\#  
    ;

    const allocator = std.testing.allocator;
    const b = try Bitfield.initFromString(allocator, s, .{ .char0 = ' ', .char1 = '#' });
    defer b.deinit(allocator);
    const to_s = try std.fmt.allocPrint(allocator, "{f}", .{b.formatCustom(' ', '#')});
    defer allocator.free(to_s);
    try std.testing.expectEqualStrings(s, to_s);
}
