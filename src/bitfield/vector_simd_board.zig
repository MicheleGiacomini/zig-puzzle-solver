const bf = @import("aligned_bitfield.zig");
const std = @import("std");
const assert = std.debug.assert;

const PieceError = error{
    TooWide,
    TooTall,
};

pub const vector_width = 8;
pub const V = @Vector(vector_width, bf.Bitfield.Elem);
const zero_v: V = @splat(0);
const one_v: V = @splat(1);

pub const Piece = struct {
    store: []bf.Bitfield.Elem,
    width: usize,
    height: usize,
    area: usize,

    pub fn init(allocator: std.mem.Allocator, b: bf.Bitfield) !Piece {
        if (b.width > bf.Bitfield.elem_bit_width) {
            return PieceError.TooWide;
        }
        var area: usize = 0;
        var bitreader = b.bitReader();
        while (bitreader.next()) |i| {
            if (i.val) {
                area += 1;
            }
        }
        const store_len = std.math.divCeil(bf.Bitfield.Elem, b.height, vector_width) catch unreachable;
        const store = try allocator.alloc(bf.Bitfield.Elem, store_len * vector_width);
        @memset(store, 0);
        @memcpy(store[0..b.data.len], b.data);

        return Piece{
            .store = store,
            .width = b.width,
            .height = b.height,
            .area = area,
        };
    }

    pub fn initFromString(allocator: std.mem.Allocator, s: []const u8, config: bf.Bitfield.FromStringConfig) !Piece {
        var tmp = try bf.Bitfield.initFromString(allocator, s, config);
        defer tmp.deinit(allocator);
        var b = try tmp.trimWhiteSpace(allocator);
        defer b.deinit(allocator);
        if (b.width > bf.Bitfield.elem_bit_width) {
            return PieceError.TooWide;
        }

        var area: usize = 0;
        var bitreader = b.bitReader();
        while (bitreader.next()) |i| {
            if (i.val) {
                area += 1;
            }
        }
        const store_len = std.math.divCeil(bf.Bitfield.Elem, b.height, vector_width) catch unreachable;
        const store = try allocator.alloc(bf.Bitfield.Elem, store_len * vector_width);
        @memset(store, 0);
        @memcpy(store[0..b.data.len], b.data);

        return Piece{
            .store = store,
            .width = b.width,
            .height = b.height,
            .area = area,
        };
    }

    pub fn deinit(self: *Piece, allocator: std.mem.Allocator) void {
        allocator.free(self.store);
    }

    pub fn format(self: *const Piece, writer: *std.Io.Writer) !void {
        var i: usize = 0;
        const one_left = 1 << @intCast(bf.Bitfield.elem_bit_width - 1);
        while (i < self.height) : (i += 1) {
            var j: usize = 0;
            const elem = self.store[i];
            while (j < self.width) : (j += 1) {
                const next_char: u8 = if (elem << @intCast(j) & one_left > 0) '1' else '0';
                try writer.print("{c}", .{next_char});
            }
            if (i < self.height - 1) {
                try writer.print("\n", .{});
            }
        }
    }

    pub fn rotate(self: *Piece, allocator: std.mem.Allocator) !Piece {
        var b_self = try bf.Bitfield.init(allocator, self.width, self.height);
        defer b_self.deinit(allocator);
        @memcpy(b_self.data, self.store[0..self.height]);
        var b = try bf.Bitfield.init(allocator, self.height, self.width);
        defer b.deinit(allocator);
        var self_iter = b_self.bitReader();
        while (self_iter.next()) |elem| {
            if (elem.val) {
                b.set(self.height - elem.y - 1, elem.x, true);
            }
        }
        return Piece.init(allocator, b);
    }

    pub fn equal(self: *const Piece, other: *const Piece) bool {
        if (self.height != other.height) {
            return false;
        }
        var i: usize = 0;
        while (i < self.height) : (i += 1) {
            if (self.store[i] != other.store[i]) {
                return false;
            }
        }
        return true;
    }
};

pub const BoardErr = error{ InsertCollision, RemoveMismatch, WidthOverflow, HeightOverflow, WidthAndHeightOverflow };

pub const Board = struct {
    current: []Elem,
    bit_field: bf.Bitfield,
    width: usize,
    height: usize,

    const Elem = bf.Bitfield.Elem;
    const elem_bit_width = bf.Bitfield.elem_bit_width;
    const max_elem = bf.Bitfield.max_elem;
    const ChangeElement = struct { index: usize, value: Elem };

    pub fn init(
        allocator: std.mem.Allocator,
        width: usize,
        height: usize,
    ) !Board {
        const bit_field = try bf.Bitfield.init(allocator, width, height);
        const store_len = bit_field.data.len + vector_width;
        const current = try allocator.alloc(Elem, store_len);
        @memset(current, 0);
        return Board{
            .current = current,
            .bit_field = bit_field,
            .width = width,
            .height = height,
        };
    }

    pub fn initFromString(
        allocator: std.mem.Allocator,
        s: []const u8,
        config: bf.Bitfield.FromStringConfig,
    ) !Board {
        const bit_field = try bf.Bitfield.initFromString(allocator, s, config);
        const store_len = bit_field.data.len + vector_width;
        const current = try allocator.alloc(Elem, store_len);
        @memset(current, 0);
        update_current_from_bitfield(current, &bit_field);
        return Board{
            .bit_field = bit_field,
            .current = current,
            .width = bit_field.width,
            .height = bit_field.height,
        };
    }

    pub fn deinit(
        self: *Board,
        allocator: std.mem.Allocator,
    ) void {
        self.bit_field.deinit(allocator);
        allocator.free(self.current);
    }

    pub fn format(self: *const Piece, writer: *std.Io.Writer) !void {
        var i: usize = 0;
        const one_left = 1 << @intCast(bf.Bitfield.elem_bit_width - 1);
        while (i < self.height) : (i += 1) {
            var j: usize = 0;
            const elem = self.store[i];
            while (j < self.width) : (j += 1) {
                const next_char: u8 = if (elem << @intCast(j) & one_left > 0) '1' else '0';
                try writer.print("{c}", .{next_char});
            }

            try writer.print("\n", .{});
        }
    }

    fn index_to_bitfield_index(self: *const Board, index: usize) usize {
        const col = @divTrunc(index, self.height);
        const row = @mod(index, self.height);
        return row * self.bit_field.row_size + col;
    }

    pub fn update_bitfield(self: *Board) void {
        var index: usize = 0;
        for (self.current) |elem| {
            self.bit_field.data[self.index_to_bitfield_index(index)] = elem;
            index += 1;
            if (index >= self.bit_field.data.len) {
                break;
            }
        }
    }

    fn bitfield_index_to_index(row_width: usize, height: usize, index: usize) usize {
        const col = @mod(index, row_width);
        const row = @divTrunc(index, row_width);
        return col * height + row;
    }

    fn update_current_from_bitfield(current: []Elem, bitfield: *const bf.Bitfield) void {
        var index: usize = 0;
        for (bitfield.data) |elem| {
            current[bitfield_index_to_index(bitfield.row_size, bitfield.height, index)] = elem;
            index += 1;
        }
    }

    fn iterateCheckAndApplyNonOverlapping(
        self: *Board,
        piece: *const Piece,
        x: usize,
        y: usize,
        comptime err: type,
        comptime check: ?*const fn (V, V) ?err,
        comptime action: *const fn (V, V) V,
        comptime actionScalar: *const fn (Elem, Elem) Elem,
        next_check_maybe_ok: ?*usize,
    ) err!void {
        const column_index = @divTrunc(x, elem_bit_width);
        const piece_shift: V = @splat(@mod(x, elem_bit_width));
        const row_index = y;
        const board_slice_start = column_index * self.height + row_index;
        var i: usize = 0;
        while (i < piece.height) : (i += vector_width) {
            const board_elem: V = self.current[board_slice_start + i ..][0..vector_width].*;
            const piece_elem_unshifted: V = piece.store[i..][0..vector_width].*;
            const piece_elem = piece_elem_unshifted >> @intCast(piece_shift);
            if (check) |c| {
                const check_result = c(board_elem, piece_elem);
                if (check_result) |e| {
                    if (next_check_maybe_ok) |n| {
                        self.find_next_maybe_ok(
                            err,
                            c,
                            board_elem,
                            column_index,
                            piece_shift,
                            piece.width,
                            piece_elem,
                            n,
                        );
                    }
                    self.reset(actionScalar, i, board_slice_start, piece, piece_shift[0]);
                    return e;
                }
            }
            self.current[board_slice_start + i ..][0..vector_width].* = action(board_elem, piece_elem);
        }
    }

    fn find_next_maybe_ok(
        self: *const Board,
        comptime err: type,
        comptime c: *const fn (V, V) ?err,
        board_elem: V,
        column_index: usize,
        piece_shift: V,
        piece_width: usize,
        piece_elem: V,
        n: *usize,
    ) void {
        const piece_right_edge = piece_shift[0] + piece_width;
        const last = column_index == self.bit_field.row_size;
        const rightmost_position = if (last) self.bit_field.last_line_elem_len else elem_bit_width;
        const max_shift_test = rightmost_position - piece_right_edge;
        var s = one_v;
        shift_while: while (s[0] < max_shift_test) : (s += one_v) {
            _ = c(board_elem, piece_elem >> @intCast(s)) orelse {
                break :shift_while;
            } catch continue;
        }
        n.* = s[0];
    }

    fn reset(
        self: *Board,
        comptime action: *const fn (Elem, Elem) Elem,
        i_start: usize,
        board_slice_start: usize,
        piece: *const Piece,
        piece_shift: usize,
    ) void {
        var i = i_start;
        while (i > 0) : (i -= 1) {
            self.current[board_slice_start + i - 1] = action(self.current[board_slice_start + i - 1], piece.store[i - 1] >> @intCast(piece_shift));
        }
    }

    fn iterateCheckAndApplyOverlapping(
        self: *Board,
        piece: *const Piece,
        x: usize,
        y: usize,
        comptime err: type,
        comptime check: ?*const fn (u64, u64) ?err,
        comptime action: *const fn (u64, u64) u64,
        next_check_maybe_ok: ?*usize,
    ) err!void {
        const column_index = @divTrunc(x, elem_bit_width);
        const elem_shift_right = @mod(x, elem_bit_width);
        const elem_shift_left = elem_bit_width - elem_shift_right;
        const row_index = y;
        const board_slice_start_first = column_index * self.height + row_index;
        const board_slice_start_second = board_slice_start_first + self.height;
        _ = next_check_maybe_ok;
        // const board_slice_end = board_slice_start + piece.height;
        // const board_slice = self.current[board_slice_start..board_slice_end];
        var i: usize = 0;
        while (i < piece.height) : (i += 1) {
            if (check) |c| {
                const check_result_first = c(self.current[board_slice_start_first + i], piece.store.data[i] >> @intCast(elem_shift_right));
                const check_result_second = c(self.current[board_slice_start_second + i], piece.store.data[i] << @intCast(elem_shift_left));
                if (check_result_first) |e| {
                    while (i > 0) : (i -= 1) {
                        self.current[board_slice_start_first + i] = action(self.current[board_slice_start_first + i - 1], piece.store.data[i - 1] >> @intCast(elem_shift_right));
                        self.current[board_slice_start_second + i] = action(self.current[board_slice_start_second + i - 1], piece.store.data[i - 1] << @intCast(elem_shift_left));
                    }
                    return e;
                } else if (check_result_second) |e| {
                    while (i > 0) : (i -= 1) {
                        self.current[board_slice_start_first + i] = action(self.current[board_slice_start_first + i - 1], piece.store.data[i - 1] >> @intCast(elem_shift_right));
                        self.current[board_slice_start_second + i] = action(self.current[board_slice_start_second + i - 1], piece.store.data[i - 1] << @intCast(elem_shift_left));
                    }
                    return e;
                }
                self.current[board_slice_start_first + i] = action(self.current[board_slice_start_first + i], piece.store.data[i] >> @intCast(elem_shift_right));
                self.current[board_slice_start_second + i] = action(self.current[board_slice_start_second + i], piece.store.data[i] << @intCast(elem_shift_left));
            }
        }
    }

    fn iterateCheckAndApply(
        self: *Board,
        piece: *const Piece,
        x: usize,
        y: usize,
        comptime err: type,
        comptime check: ?*const fn (V, V) ?err,
        comptime action: *const fn (V, V) V,
        comptime actionScalar: *const fn (Elem, Elem) Elem,
        next_check_maybe_ok: ?*usize,
    ) err!void {
        const width_overflow = self.width < x + piece.width;
        const height_overflow = self.height < y + piece.height;

        if (width_overflow and height_overflow) {
            return BoardErr.WidthAndHeightOverflow;
        }
        if (width_overflow) {
            return BoardErr.WidthOverflow;
        }
        if (height_overflow) {
            return BoardErr.HeightOverflow;
        }

        if (@mod(x, elem_bit_width) + piece.width > elem_bit_width) {
            @panic("Unimplemented");
            // return iterateCheckAndApplyOverlapping(self, piece, x, y, err, check, action, next_check_maybe_ok);
        } else {
            return iterateCheckAndApplyNonOverlapping(self, piece, x, y, err, check, action, actionScalar, next_check_maybe_ok);
        }
    }

    fn iterateAndApply(self: *Board, piece: *const Piece, x: usize, y: usize, action: *const fn (u64, u64) u64) void {
        iterateCheckAndApply(self, piece, x, y, void, null, action) catch unreachable;
    }

    /// Takes a smaller bitfield and inserts it at offset in self. Returns an error if self & other has any "on" bit.
    pub fn insert(self: *Board, piece: *const Piece, x: usize, y: usize, next_check_maybe_ok: ?*usize) BoardErr!void {
        const Local = struct {
            pub fn check(eSelf: V, ePiece: V) ?BoardErr {
                if (@reduce(.Or, eSelf & ePiece > zero_v)) {
                    return BoardErr.InsertCollision;
                }
                return null;
            }
            pub fn action(eSelf: V, ePiece: V) V {
                return eSelf ^ ePiece;
            }
            pub fn actionScalar(eSelf: Elem, ePiece: Elem) Elem {
                return eSelf ^ ePiece;
            }
        };

        return iterateCheckAndApply(self, piece, x, y, BoardErr, Local.check, Local.action, Local.actionScalar, next_check_maybe_ok);
    }

    pub fn remove(self: *Board, piece: *const Piece, x: usize, y: usize) BoardErr!void {
        const Local = struct {
            pub fn check(eSelf: V, ePiece: V) ?BoardErr {
                if (@reduce(.Or, (eSelf & ePiece) ^ ePiece > zero_v)) {
                    return BoardErr.RemoveMismatch;
                }
                return null;
            }
            pub fn action(eSelf: V, ePiece: V) V {
                return eSelf ^ ePiece;
            }
            pub fn actionScalar(eSelf: Elem, ePiece: Elem) Elem {
                return eSelf ^ ePiece;
            }
        };

        return iterateCheckAndApply(self, piece, x, y, BoardErr, Local.check, Local.action, Local.actionScalar, null);
    }
};

test "Remove piece full board" {
    const s =
        \\010
        \\111
    ;

    const board_s =
        \\1111111111
        \\1111111111
        \\1111111111
        \\1111111111
        \\1111111111
        \\1111111111
        \\1111111111
        \\1111111111
        \\1111111111
        \\1111111111
    ;

    const exp =
        \\1111111111
        \\1111111111
        \\1111111111
        \\1111011111
        \\1110001111
        \\1111111111
        \\1111111111
        \\1111111111
        \\1111111111
        \\1111111111
    ;
    const allocator = std.testing.allocator;
    var piece = try Piece.initFromString(allocator, s, .{});
    defer piece.deinit(allocator);
    var board = try Board.initFromString(allocator, board_s, .{});
    defer board.deinit(allocator);
    try board.remove(&piece, 3, 3);
    board.update_bitfield();
    const actual = try std.fmt.allocPrint(allocator, "{f}", .{board.bit_field});
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(exp, actual);
}

test "Insert+remove piece no collision" {
    const s =
        \\010
        \\111
    ;

    const exp =
        \\0000000000
        \\0000000000
        \\0000000000
        \\0000000000
        \\0000000000
        \\0000000000
        \\0000000000
        \\0000000000
        \\0000000000
        \\0000000000
    ;
    const allocator = std.testing.allocator;
    var piece = try Piece.initFromString(allocator, s, .{});
    defer piece.deinit(allocator);
    var board = try Board.init(allocator, 10, 10);
    defer board.deinit(allocator);
    try board.insert(&piece, 3, 3, null);
    try board.remove(&piece, 3, 3);
    board.update_bitfield();
    const actual = try std.fmt.allocPrint(allocator, "{f}", .{board.bit_field});
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(exp, actual);
}

test "Insert+remove piece no collision across element boundaries" {
    const s =
        \\010
        \\111
    ;

    const exp =
        \\0000000000
        \\0000000000
        \\0000000000
        \\0000000000
        \\0000000000
        \\0000000000
        \\0000000000
        \\0000000000
        \\0000000000
        \\0000000000
    ;
    const allocator = std.testing.allocator;
    var piece = try Piece.initFromString(allocator, s, .{});
    defer piece.deinit(allocator);
    var board = try Board.init(allocator, 10, 10);
    defer board.deinit(allocator);
    try board.insert(&piece, 2, 5, null);
    try board.remove(&piece, 2, 5);
    board.update_bitfield();
    const actual = try std.fmt.allocPrint(allocator, "{f}", .{board.bit_field});
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(exp, actual);
}

test "Rotate piece" {
    const s =
        \\100
        \\111
    ;

    const exp =
        \\11
        \\10
        \\10
    ;
    const allocator = std.testing.allocator;
    var piece = try Piece.initFromString(allocator, s, .{});
    defer piece.deinit(allocator);
    var rotated = try piece.rotate(allocator);
    defer rotated.deinit(allocator);
    const actual = try std.fmt.allocPrint(allocator, "{f}", .{rotated});
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(exp, actual);
}

test "Insert piece 15x15 at 4,10" {
    const s =
        \\111
        \\111
        \\111
    ;

    const board_s =
        \\111111111111111
        \\111111111111111
        \\111111111111111
        \\111111111111111
        \\111111111111111
        \\111111111111110
        \\111111111111110
        \\111111111111110
        \\111111111111110
        \\111111111111110
        \\111100000011110
        \\111111110011110
        \\111111110011110
        \\111111110000000
        \\000011110000000
    ;

    const allocator = std.testing.allocator;
    var piece = try Piece.initFromString(allocator, s, .{});
    defer piece.deinit(allocator);
    var board = try Board.initFromString(allocator, board_s, .{});
    defer board.deinit(allocator);
    const result = board.insert(&piece, 4, 10, null);
    try std.testing.expectError(BoardErr.InsertCollision, result);
    board.update_bitfield();
    const actual = try std.fmt.allocPrint(allocator, "{f}", .{board.bit_field});
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(board_s, actual);
}
