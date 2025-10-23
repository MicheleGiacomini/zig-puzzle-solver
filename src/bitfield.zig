const std = @import("std");

pub const BitfieldErr = error{ InconsistentLineLength, UnexpectedCharacter, TrimTooLarge };

/// Represent a rectangular matrix of boolean values
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
        current: Elem,
        offset: usize,
        index: usize,
        bf: *const Bitfield,

        pub fn next(self: *BitReader) ?Item {
            if (self.offset == elem_bit_width) {
                self.offset = 0;
                self.index += 1;
                if (self.index == self.bf.data.len) {
                    return null;
                }
                self.current = self.bf.data[self.index];
            }
            const total_offset = self.offset + self.index * elem_bit_width;
            const x = @mod(total_offset, self.bf.width);
            const y = @divTrunc(total_offset, self.bf.width);
            if (y >= self.bf.height) {
                return null;
            }
            const mask = 1 << elem_bit_width - 1;
            const val = self.current & mask > 0;
            self.current = self.current << 1;
            self.offset += 1;
            return Item{ .x = x, .y = y, .val = val };
        }
    };

    /// Return an iterator that returns one bit at a time together with the x(col) and y(row) coordinates.
    /// Call `next()` to advance.
    pub fn bitReader(self: *const Bitfield) BitReader {
        return BitReader{
            .current = self.data[0],
            .offset = 0,
            .index = 0,
            .bf = self,
        };
    }

    /// Set a single bit to a given value
    pub fn set(self: *Bitfield, x: usize, y: usize, val: bool) void {
        const total_offset = y * self.width + x;
        const index = @divTrunc(total_offset, elem_bit_width);
        const offset = @mod(total_offset, elem_bit_width);
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

    pub const BitWriter = struct {
        start_index: usize,
        current_index: usize,
        bf: *Bitfield,
        buf: Elem = 0,

        fn writeBuf(self: *BitWriter) void {
            var bf = self.bf;
            const indOff = Bitfield.indexOffsetFromTotalOffset(self.current_index);
            const indOffStart = Bitfield.indexOffsetFromTotalOffset(self.start_index);
            const mask_end = max_elem << @intCast(elem_bit_width - indOff.offset - 1);
            const mask_start = switch (indOff.index - indOffStart.index) {
                0 => max_elem >> @intCast(indOffStart.offset),
                else => max_elem,
            };
            const mask = mask_start & mask_end;
            bf.data[indOff.index] = bf.data[indOff.index] & mask | (self.buf << @intCast(elem_bit_width - indOff.offset - 1));
        }

        fn isIndexAfterEnd(self: *BitWriter, index: usize) bool {
            return index >= self.bf.*.width * self.bf.*.height;
        }

        pub fn reachedEnd(self: *BitWriter) bool {
            return isIndexAfterEnd(self, self.current_index);
        }

        pub fn flush(self: *BitWriter) void {
            const indOff = Bitfield.indexOffsetFromTotalOffset(self.current_index);
            if (indOff.offset == 0) {
                return;
            }
            self.current_index -= 1;
            self.writeBuf();
            self.current_index += 1;
        }

        pub fn write(self: *BitWriter, val: bool) void {
            if (self.reachedEnd()) {
                return;
            }

            const indOff = Bitfield.indexOffsetFromTotalOffset(self.current_index);
            self.buf = self.buf << 1;
            if (val) {
                self.buf = self.buf | 1;
            }

            if (indOff.offset == elem_bit_width - 1 or self.isIndexAfterEnd(self.current_index + 1)) {
                self.writeBuf();
                self.buf = 0;
            }
            self.current_index += 1;
        }
    };

    /// Returns a buffered writer that writes one bit at a time and advances starting from x(col) x_start and y(row) y_start.
    /// Available methods are:
    ///     - `write(bool) void` to write a single value and advance
    ///     - `flush() void` to flush the current buffer, data is automatically flushed when writing to the rightmost bit of an element
    ///     - `reachedEnd() bool` turns `true` after writing the last (width-1, height-1) bit of the bitfield.
    pub fn bitWriter(self: *Bitfield, x_start: usize, y_start: usize) BitWriter {
        const idx = self.totalOffsetFromXY(x_start, y_start);
        return BitWriter{
            .bf = self,
            .start_index = idx,
            .current_index = idx,
        };
    }

    /// Trim a given number of rows and columns from the bitfield.
    /// Returns `TrimTooLarge` when trying to remove more rows or columns than available.
    pub fn trim(self: *const Bitfield, allocator: std.mem.Allocator, rows_start: usize, rows_end: usize, cols_start: usize, cols_end: usize) !Bitfield {
        if (rows_start + rows_end > self.height or cols_start + cols_end > self.width) {
            return BitfieldErr.TrimTooLarge;
        }
        var b = try Bitfield.init(allocator, self.width - cols_start - cols_end, self.height - rows_start - rows_end);
        var readerSelf = self.bitReader();
        var writerTarget = b.bitWriter(0, 0);
        const x_start = cols_start;
        const x_end = self.width - cols_end;
        const y_start = rows_start;
        const y_end = self.height - rows_end;
        while (readerSelf.next()) |val| {
            if (val.x >= x_start and val.x < x_end and val.y >= y_start and val.y < y_end) {
                writerTarget.write(val.val);
            }
        }
        writerTarget.flush();
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
    const data = [_]Bitfield.Elem{0b0100011000000000000000000000000000000000000000000000000000000000};

    const allocator = std.testing.allocator;
    var b = try Bitfield.initFromString(allocator, s, .{});
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
        0b0000100000000000000000000000000000000000000000000000000000000000,
        0b0000100000000000000000000000000000000000000000000000000000000000,
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

test "Filler" {
    const s_0 =
        \\000
        \\000
        \\000
    ;

    const s_1 =
        \\000
        \\001
        \\100
    ;

    const s_2 =
        \\000
        \\001
        \\101
    ;
    const allocator = std.testing.allocator;
    var b = try Bitfield.init(allocator, 3, 3);
    defer b.deinit(allocator);

    var filler = b.bitWriter(2, 1);
    filler.write(true);
    filler.write(true);

    // try std.testing.expect(!filler.reachedEnd());
    const to_s_0 = try std.fmt.allocPrint(allocator, "{f}", .{b});
    defer allocator.free(to_s_0);
    try std.testing.expectEqualStrings(s_0, to_s_0);

    filler.flush();

    // try std.testing.expect(!filler.reachedEnd());
    const to_s_1 = try std.fmt.allocPrint(allocator, "{f}", .{b});
    defer allocator.free(to_s_1);
    try std.testing.expectEqualStrings(s_1, to_s_1);

    filler.write(false);
    filler.write(true);

    // try std.testing.expect(filler.reachedEnd());
    const to_s_2 = try std.fmt.allocPrint(allocator, "{f}", .{b});
    defer allocator.free(to_s_2);
    try std.testing.expectEqualStrings(s_2, to_s_2);
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
