const std = @import("std");

pub const BitfieldErr = error{ InconsistentLineLength, UnexpectedCharacter, TrimTooLarge };

/// Represent a rectangular matrix of boolean values
pub const Bitfield = struct {
    width: usize,
    height: usize,
    row_size: usize,
    data: []Elem,
    last_line_elem_len: usize,

    pub const Elem = u64;
    pub const elem_bit_width: usize = @sizeOf(Elem) * 8;
    pub const max_elem: Elem = std.math.maxInt(Elem);

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Bitfield {
        const row_size = std.math.divCeil(usize, width, elem_bit_width) catch unreachable;
        const data = try allocator.alloc(Elem, row_size * height);
        @memset(data, 0);
        return Bitfield{
            .width = width,
            .height = height,
            .data = data,
            .row_size = row_size,
            .last_line_elem_len = @mod(width, elem_bit_width),
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
            if (bits_copied > 0) {
                try tmp.append(allocator, buf << @intCast(elem_bit_width - bits_copied));
                bits_copied = 0;
                buf = 0;
            }
        }
        const mod_width = @mod(width, elem_bit_width);
        const last_line_elem_len = if (mod_width == 0) 64 else mod_width;
        return Bitfield{
            .width = width,
            .height = height,
            .data = try tmp.toOwnedSlice(allocator),
            .row_size = std.math.divCeil(usize, width, elem_bit_width) catch unreachable,
            .last_line_elem_len = last_line_elem_len,
        };
    }

    const F = struct {
        char0: u8 = '0',
        char1: u8 = '1',
        bf: *const Bitfield,

        pub fn format(self: F, writer: *std.Io.Writer) !void {
            var iter = self.bf.bitReader();
            var last_y: usize = 0;
            while (iter.next()) |position| {
                if (last_y != position.y) {
                    try writer.print("\n", .{});
                    last_y = position.y;
                }
                const elem = position.val;
                const next_char =
                    if (elem) self.char1 else self.char0;
                try writer.print("{c}", .{next_char});
            }
        }
    };

    /// Call like this: `const to_s = try std.fmt.allocPrint(allocator, "{f}", .{b.formatCustom(' ', '#')});`
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

    const Item = packed struct {
        x: usize,
        y: usize,
        val: bool,
    };

    const BitReader = struct {
        current: ?Position,
        offset: usize,
        iterator: PositionIterator,
        elem: Elem,

        const leftmost_bit: Elem = 1 << @intCast(elem_bit_width - 1);

        pub fn next(self: *BitReader) ?Item {
            const len = if (self.current) |curr| curr.len else elem_bit_width;
            if (self.offset >= len) {
                self.offset = 0;
            }
            if (self.offset == 0) {
                self.current = self.iterator.next();
                if (self.current) |curr| {
                    self.elem = curr.elem;
                } else {
                    return null;
                }
            }

            const val = self.elem & leftmost_bit;
            const x = self.current.?.x + self.offset;
            self.elem = self.elem << 1;
            self.offset += 1;

            return Item{ .x = x, .y = self.current.?.y, .val = val > 0 };
        }
    };

    /// Return an iterator that returns one bit at a time together with the x(col) and y(row) coordinates.
    /// Call `next()` to advance.
    pub fn bitReader(self: *const Bitfield) BitReader {
        const iterator = PositionIterator.init(self);
        return BitReader{
            .current = null,
            .offset = 0,
            .iterator = iterator,
            .elem = 0,
        };
    }

    /// Set a single bit to a given value
    pub fn set(self: *Bitfield, x: usize, y: usize, val: bool) void {
        const index = y * self.row_size + @divTrunc(x, elem_bit_width);
        const offset = @mod(x, elem_bit_width);
        const one: Elem = 1;
        const mask: Elem = one << @intCast(elem_bit_width - 1 - offset);
        if (val) {
            self.data[index] = self.data[index] | mask;
        } else {
            self.data[index] = self.data[index] & ~mask;
        }
    }

    pub const IndexOffset = struct {
        index: usize,
        offset: usize,
    };

    pub const XY = struct {
        x: usize,
        y: usize,
    };

    pub fn indexOffsetFromTotalOffset(total_offset: usize) IndexOffset {
        const index = @divTrunc(total_offset, elem_bit_width);
        const offset = @mod(total_offset, elem_bit_width);
        return IndexOffset{
            .index = index,
            .offset = offset,
        };
    }

    pub fn indexOffsetFromXY(self: *const Bitfield, x: usize, y: usize) IndexOffset {
        const total_offset = y * self.width + x;
        return self.indexOffsetFromTotalOffset(total_offset);
    }

    pub fn xyFromIndexOffset(self: *const Bitfield, index: usize, offset: usize) XY {
        const totalOffset = offset + index * elem_bit_width;
        const y = @divTrunc(totalOffset, self.width);
        const x = @mod(totalOffset, self.width);
        return XY{
            .x = x,
            .y = y,
        };
    }

    pub fn totalOffsetFromXY(self: *const Bitfield, x: usize, y: usize) usize {
        return y * self.width + x;
    }

    const Position = struct {
        x: usize,
        y: usize,
        elem: Elem,
        len: usize,
    };

    const PositionIterator = struct {
        x: usize,
        y: usize,
        index: usize,
        line_index: usize,
        bf: *const Bitfield,

        pub fn init(bf: *const Bitfield) PositionIterator {
            return PositionIterator{
                .x = 0,
                .y = 0,
                .index = 0,
                .line_index = 0,
                .bf = bf,
            };
        }

        fn elem_len(self: *const PositionIterator) usize {
            if (self.line_index == self.bf.row_size - 1) {
                return self.bf.last_line_elem_len;
            } else {
                return elem_bit_width;
            }
        }

        pub fn next(self: *PositionIterator) ?Position {
            if (self.y >= self.bf.height) {
                return null;
            }
            const return_value = Position{
                .x = self.x,
                .y = self.y,
                .elem = self.bf.data[self.index],
                .len = self.elem_len(),
            };
            self.index += 1;
            self.line_index += 1;
            self.x += elem_bit_width;
            if (self.x >= self.bf.width) {
                self.y += 1;
                self.x = 0;
                self.line_index = 0;
            }
            return return_value;
        }
    };

    /// Trim a given number of rows and columns from the bitfield.
    /// Returns `TrimTooLarge` when trying to remove more rows or columns than available.
    pub fn trim(self: *const Bitfield, allocator: std.mem.Allocator, rows_start: usize, rows_end: usize, cols_start: usize, cols_end: usize) !Bitfield {
        if (rows_start + rows_end > self.height or cols_start + cols_end > self.width) {
            return BitfieldErr.TrimTooLarge;
        }
        var b = try Bitfield.init(allocator, self.width - cols_start - cols_end, self.height - rows_start - rows_end);
        var readerSelf = self.bitReader();
        const x_start = cols_start;
        const x_end = self.width - cols_end;
        const y_start = rows_start;
        const y_end = self.height - rows_end;
        while (readerSelf.next()) |val| {
            if (val.x >= x_start and val.x < x_end and val.y >= y_start and val.y < y_end) {
                b.set(val.x - x_start, val.y - y_start, val.val);
            }
        }
        return b;
    }

    /// Trim all completely empty rows and columns from the perimeter of the bitfield
    pub fn trimWhiteSpace(self: *const Bitfield, allocator: std.mem.Allocator) !Bitfield {
        var foundFirstNonEmptyRow = false;
        var lastNonEmptyRow: usize = 0;
        var firstNonEmptyRow = self.height - 1;

        var firstNonEmptyCol = self.width - 1;
        var lastNonEmptyCol: usize = 0;

        var currentFirstNonEmptyCol = self.width - 1;
        var currentLastNonEmptyCol: usize = 0;
        var foundFirstNonEmptyCol = false;

        var readerSelf = self.bitReader();
        while (readerSelf.next()) |val| {
            if (val.x == 0) {
                currentFirstNonEmptyCol = self.width - 1;
                currentLastNonEmptyCol = 0;
                foundFirstNonEmptyCol = false;
            }

            if (val.val) {
                if (!foundFirstNonEmptyRow) {
                    foundFirstNonEmptyRow = true;
                    firstNonEmptyRow = val.y;
                }
                lastNonEmptyRow = val.y;
                if (!foundFirstNonEmptyCol) {
                    foundFirstNonEmptyCol = true;
                    currentFirstNonEmptyCol = val.x;
                }
                currentLastNonEmptyCol = val.x;
            }

            if (val.x == self.width - 1) {
                firstNonEmptyCol = @min(firstNonEmptyCol, currentFirstNonEmptyCol);
                lastNonEmptyCol = @max(lastNonEmptyCol, currentLastNonEmptyCol);
            }
        }
        if (lastNonEmptyRow == 0) {
            return Bitfield.init(allocator, 0, 0);
        }
        return self.trim(allocator, firstNonEmptyRow, self.height - lastNonEmptyRow - 1, firstNonEmptyCol, self.width - lastNonEmptyCol - 1);
    }

    /// Whether the two bitfields contain the same data.
    pub fn equal(self: *const Bitfield, other: *const Bitfield) bool {
        if (self.width != other.width or self.height != other.height) return false;
        var i: usize = 0;
        while (i < self.data.len) : (i += 1) {
            if (self.data[i] != other.data[i]) {
                return false;
            }
        }
        return true;
    }
};

test "From string simple" {
    const s =
        \\010
        \\001
        \\100
    ;
    const data = [_]Bitfield.Elem{
        0b0100000000000000000000000000000000000000000000000000000000000000,
        0b0010000000000000000000000000000000000000000000000000000000000000,
        0b1000000000000000000000000000000000000000000000000000000000000000,
    };

    const allocator = std.testing.allocator;
    var b = try Bitfield.initFromString(allocator, s, .{});
    defer b.deinit(allocator);
    try std.testing.expectEqualSlices(Bitfield.Elem, &data, b.data);
    try std.testing.expectEqual(3, b.width);
    try std.testing.expectEqual(3, b.height);
}

test "From string single bit" {
    const s =
        \\1
    ;
    const data = [_]Bitfield.Elem{0b1000000000000000000000000000000000000000000000000000000000000000};

    const allocator = std.testing.allocator;
    var b = try Bitfield.initFromString(allocator, s, .{});
    defer b.deinit(allocator);
    try std.testing.expectEqualSlices(Bitfield.Elem, &data, b.data);
    try std.testing.expectEqual(1, b.width);
    try std.testing.expectEqual(1, b.height);
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
    var b = try Bitfield.initFromString(allocator, s, .{});
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
        0b0000000000000000000000000000000000000000000000000000000000000000,
        0b0010000000000000000000000000000000000000000000000000000000000000,
        0b0000000000000000000000000000000000000000000000000000000000000000,
        0b1000000000000000000000000000000000000000000000000000000000000000,
        0b0000000000000000000000000000000000000000000000000000000000000000,
    };

    const allocator = std.testing.allocator;
    var b = try Bitfield.initFromString(allocator, s, .{});
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
    var b = try Bitfield.initFromString(allocator, s, .{});
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
    var b = try Bitfield.initFromString(allocator, s, .{});
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
    var b = try Bitfield.initFromString(allocator, s, .{});
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
    var b = try Bitfield.initFromString(allocator, s, .{ .char0 = ' ', .char1 = '#' });
    defer b.deinit(allocator);
    const to_s = try std.fmt.allocPrint(allocator, "{f}", .{b.formatCustom(' ', '#')});
    defer allocator.free(to_s);
    try std.testing.expectEqualStrings(s, to_s);
}

test "Simple item iterator" {
    const s =
        \\010
        \\001
        \\100
    ;

    const allocator = std.testing.allocator;
    var b = try Bitfield.initFromString(allocator, s, .{});
    defer b.deinit(allocator);
    var iter = b.bitReader();
    var current = iter.next();
    try std.testing.expect(current.?.val == false);
    try std.testing.expect(current.?.x == 0);
    try std.testing.expect(current.?.y == 0);
    current = iter.next();
    try std.testing.expect(current.?.val == true);
    try std.testing.expect(current.?.x == 1);
    try std.testing.expect(current.?.y == 0);
    current = iter.next();
    try std.testing.expect(current.?.val == false);
    try std.testing.expect(current.?.x == 2);
    try std.testing.expect(current.?.y == 0);
    current = iter.next();
    try std.testing.expect(current.?.val == false);
    try std.testing.expect(current.?.x == 0);
    try std.testing.expect(current.?.y == 1);
    current = iter.next();
    try std.testing.expect(current.?.val == false);
    try std.testing.expect(current.?.x == 1);
    try std.testing.expect(current.?.y == 1);
    current = iter.next();
    try std.testing.expect(current.?.val == true);
    try std.testing.expect(current.?.x == 2);
    try std.testing.expect(current.?.y == 1);
    current = iter.next();
    try std.testing.expect(current.?.val == true);
    try std.testing.expect(current.?.x == 0);
    try std.testing.expect(current.?.y == 2);
    current = iter.next();
    try std.testing.expect(current.?.val == false);
    try std.testing.expect(current.?.x == 1);
    try std.testing.expect(current.?.y == 2);
    current = iter.next();
    try std.testing.expect(current.?.val == false);
    try std.testing.expect(current.?.x == 2);
    try std.testing.expect(current.?.y == 2);
}

test "simple set" {
    const s =
        \\010
        \\001
        \\100
    ;

    const exp =
        \\010
        \\001
        \\101
    ;
    const allocator = std.testing.allocator;
    var b = try Bitfield.initFromString(allocator, s, .{});
    defer b.deinit(allocator);
    b.set(2, 2, true);
    const to_s = try std.fmt.allocPrint(allocator, "{f}", .{b});
    defer allocator.free(to_s);
    try std.testing.expectEqualStrings(exp, to_s);
}

test "simple unset" {
    const s =
        \\010
        \\001
        \\100
    ;

    const exp =
        \\010
        \\001
        \\000
    ;
    const allocator = std.testing.allocator;
    var b = try Bitfield.initFromString(allocator, s, .{});
    defer b.deinit(allocator);
    b.set(0, 2, false);
    const to_s = try std.fmt.allocPrint(allocator, "{f}", .{b});
    defer allocator.free(to_s);
    try std.testing.expectEqualStrings(exp, to_s);
}

test "Trim" {
    const s =
        \\00100000
        \\00001000
        \\00000001
        \\00001000
        \\00100000
        \\01000000
        \\01000000
    ;

    const exp =
        \\10
        \\00
        \\10
    ;
    const allocator = std.testing.allocator;
    var b = try Bitfield.initFromString(allocator, s, .{});
    defer b.deinit(allocator);

    var trimmed = try b.trim(allocator, 1, 3, 4, 2);
    defer trimmed.deinit(allocator);

    // try std.testing.expect(filler.reachedEnd());
    const actual = try std.fmt.allocPrint(allocator, "{f}", .{trimmed});
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(exp, actual);
}

test "Equality" {
    const s1 =
        \\100
        \\010
        \\001
    ;
    const s2 =
        \\101
        \\010
        \\001
    ;

    const allocator = std.testing.allocator;

    var b33 = try Bitfield.init(allocator, 3, 3);
    defer b33.deinit(allocator);
    var b34 = try Bitfield.init(allocator, 3, 4);
    defer b34.deinit(allocator);
    var b43 = try Bitfield.init(allocator, 4, 3);
    defer b43.deinit(allocator);
    var b10 = try Bitfield.initFromString(allocator, s1, .{});
    defer b10.deinit(allocator);
    var b11 = try Bitfield.initFromString(allocator, s1, .{});
    defer b11.deinit(allocator);
    var b2 = try Bitfield.initFromString(allocator, s2, .{});
    defer b2.deinit(allocator);

    try std.testing.expect(b33.equal(&b33));
    try std.testing.expect(!b33.equal(&b34));
    try std.testing.expect(!b33.equal(&b43));
    try std.testing.expect(b10.equal(&b11));
    try std.testing.expect(!b10.equal(&b2));
}

test "trimWhiteSpace" {
    const s1 =
        \\101
        \\010
        \\101
    ;
    const s2 =
        \\000000000
        \\000010100
        \\000001000
        \\000010100
        \\000000000
        \\000000000
        \\000000000
    ;

    const allocator = std.testing.allocator;
    var b1 = try Bitfield.initFromString(allocator, s1, .{});
    defer b1.deinit(allocator);
    var b2 = try Bitfield.initFromString(allocator, s2, .{});
    defer b2.deinit(allocator);

    var trim_b1 = try b1.trimWhiteSpace(allocator);
    defer trim_b1.deinit(allocator);
    var trim_b2 = try b2.trimWhiteSpace(allocator);
    defer trim_b2.deinit(allocator);
    const trim_s1 = try std.fmt.allocPrint(allocator, "{f}", .{trim_b1});
    defer allocator.free(trim_s1);
    const trim_s2 = try std.fmt.allocPrint(allocator, "{f}", .{trim_b2});
    defer allocator.free(trim_s2);

    try std.testing.expectEqualStrings(s1, trim_s1);
    try std.testing.expectEqualStrings(s1, trim_s2);
}
