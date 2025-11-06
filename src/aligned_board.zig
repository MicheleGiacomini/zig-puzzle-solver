const bf = @import("aligned_bitfield.zig");
const std = @import("std");
const assert = std.debug.assert;

pub const Piece = struct {
    store: bf.Bitfield,
    width: usize,
    height: usize,

    pub fn init(b: bf.Bitfield) Piece {
        return Piece{
            .store = b,
            .width = b.width,
            .height = b.height,
        };
    }

    pub fn initFromString(allocator: std.mem.Allocator, s: []const u8, config: bf.Bitfield.FromStringConfig) !Piece {
        var tmp = try bf.Bitfield.initFromString(allocator, s, config);
        defer tmp.deinit(allocator);
        const b = try tmp.trimWhiteSpace(allocator);

        return Piece{
            .store = b,
            .width = b.width,
            .height = b.height,
        };
    }

    pub fn deinit(self: *Piece, allocator: std.mem.Allocator) void {
        self.store.deinit(allocator);
    }

    pub fn rotate(self: *Piece, allocator: std.mem.Allocator) !Piece {
        var b = try bf.Bitfield.init(allocator, self.height, self.width);
        var self_iter = self.store.bitReader();
        while (self_iter.next()) |elem| {
            if (elem.val) {
                b.set(self.height - elem.y - 1, elem.x, true);
            }
        }
        return Piece.init(b);
    }

    pub fn equal(self: *const Piece, other: *const Piece) bool {
        return self.store.equal(&other.store);
    }
};

pub const BoardErr = error{ InsertCollision, RemoveMismatch, WidthOverflow, HeightOverflow, WidthAndHeightOverflow };

pub const Board = struct {
    current: bf.Bitfield,
    buf: []ChangeElement,
    width: usize,
    height: usize,

    const Elem = bf.Bitfield.Elem;
    const elem_bit_width = bf.Bitfield.elem_bit_width;
    const max_elem = bf.Bitfield.max_elem;
    const ChangeElement = struct { index: usize, value: Elem };

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Board {
        const current = try bf.Bitfield.init(allocator, width, height);
        const buf = try allocator.alloc(ChangeElement, current.data.len);
        return Board{
            .current = current,
            .buf = buf,
            .width = width,
            .height = height,
        };
    }

    pub fn initFromString(allocator: std.mem.Allocator, s: []const u8, config: bf.FromStringConfig) !Board {
        const current = try bf.Bitfield.initFromString(allocator, s, config);
        const buf = try allocator.alloc(ChangeElement, current.data.len);
        return Board{
            .current = current,
            .buf = buf,
            .width = current.width,
            .height = current.height,
        };
    }

    pub fn deinit(self: *Board, allocator: std.mem.Allocator) void {
        self.current.deinit(allocator);
        allocator.free(self.buf);
    }

    fn iterateCheckAndApplyAligned(self: *Board, piece: *const Piece, x: usize, y: usize, comptime err: type, comptime check: ?*const fn (Elem, Elem) ?err, comptime action: *const fn (Elem, Elem) Elem, next_check_maybe_ok: ?*usize) err!void {
        const board_insert_index_start = @divTrunc(x, elem_bit_width);
        var current_piece_line: usize = 0;
        var elements_modified: usize = 0;
        while (current_piece_line < piece.height) : (current_piece_line += 1) {
            var current_piece_line_index: usize = 0;
            const board_line = y + current_piece_line;
            const board_line_insert_start = board_line * self.current.row_size + board_insert_index_start;
            while (current_piece_line_index < piece.store.row_size) : (current_piece_line_index += 1) {
                const board_elem = self.current.data[board_line_insert_start + current_piece_line_index];
                const piece_elem = piece.store.data[current_piece_line_index];
                if (check) |c| {
                    const check_result = c(board_elem, piece_elem);
                    if (check_result) |e| {
                        if (next_check_maybe_ok) |n| {
                            var s: usize = 1;
                            shift_while: while (s < elem_bit_width) : (s += 1) {
                                _ = c(board_elem, piece_elem >> @intCast(s)) orelse {
                                    break :shift_while;
                                } catch continue;
                            }
                            n.* = s;
                        }

                        var i: usize = 0;
                        while (i < elements_modified) : (i += 1) {
                            const elem = self.buf[i];
                            self.current.data[elem.index] = elem.value;
                        }
                        return e;
                    }
                }
                self.buf[elements_modified] = ChangeElement{
                    .index = board_line_insert_start + current_piece_line_index,
                    .value = board_elem,
                };
                elements_modified += 1;
                self.current.data[board_line_insert_start + current_piece_line_index] = action(board_elem, piece_elem);
            }
        }
    }

    fn iterateCheckAndApply(self: *Board, piece: *const Piece, x: usize, y: usize, comptime err: type, comptime check: ?*const fn (Elem, Elem) ?err, comptime action: *const fn (Elem, Elem) Elem, next_check_maybe_ok: ?*usize) err!void {
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

        const piece_shift_right = @mod(x, elem_bit_width);

        if (piece_shift_right == 0) {
            return self.iterateCheckAndApplyAligned(piece, x, y, comptime err, comptime check, comptime action, next_check_maybe_ok);
        }
        const board_insert_index_start = @divTrunc(x, elem_bit_width);
        var current_piece_line: usize = 0;
        var elements_modified: usize = 0;

        const first_mask = max_elem >> @intCast(piece_shift_right);
        const last_mask = max_elem << @intCast(elem_bit_width - piece_shift_right);

        while (current_piece_line < piece.height) : (current_piece_line += 1) {
            var current_piece_line_index: usize = 0;
            var last_piece_elem: Elem = 0;
            const board_line = y + current_piece_line;
            const board_line_insert_start = board_line * self.current.row_size + board_insert_index_start;

            while (current_piece_line_index < piece.store.row_size) : (current_piece_line_index += 1) {
                const board_elem = self.current.data[board_line_insert_start + current_piece_line_index];
                const piece_elem = piece.store.data[current_piece_line_index];
                const write_elem = piece_elem >> @intCast(piece_shift_right) | last_piece_elem << @intCast(elem_bit_width - piece_shift_right);
                const mask = if (current_piece_line_index == 0) first_mask else if (current_piece_line_index == piece.store.row_size - 1) last_mask else max_elem;

                if (check) |c| {
                    const check_result = c(board_elem, write_elem);
                    if (check_result) |e| {
                        if (next_check_maybe_ok) |n| {
                            findNextGood(err, c, n, board_elem, write_elem);
                            reset_board(self, elements_modified);
                            return e;
                        }
                    }

                    self.pushToBuffer(elements_modified, board_line_insert_start + current_piece_line_index, board_elem);
                    elements_modified += 1;
                    self.current.data[board_line_insert_start + current_piece_line_index] = (board_elem & ~mask) | (action(board_elem, write_elem) & mask);
                    last_piece_elem = piece_elem;
                }
            }
        }
    }

    fn pushToBuffer(self: *Board, position: usize, index: usize, elem: Elem) void {
        self.buf[position] = ChangeElement{
            .index = index,
            .value = elem,
        };
    }

    fn findNextGood(comptime err: type, comptime c: *const fn (Elem, Elem) ?err, n: *usize, board_elem: Elem, write_elem: Elem) void {
        var s: usize = 1;
        shift_while: while (s < elem_bit_width) : (s += 1) {
            _ = c(board_elem, write_elem >> @intCast(s)) orelse {
                break :shift_while;
            } catch continue;
        }
        n.* = s;
    }

    fn reset_board(self: *Board, elements_modified: usize) void {
        var i: usize = 0;
        while (i < elements_modified) : (i += 1) {
            const elem = self.buf[i];
            self.current.data[elem.index] = elem.value;
        }
    }

    fn iterateAndApply(self: *Board, piece: *const Piece, x: usize, y: usize, action: *const fn (u64, u64) u64) void {
        iterateCheckAndApply(self, piece, x, y, void, null, action) catch unreachable;
    }

    /// Takes a smaller bitfield and inserts it at offset in self. Returns an error if self & other has any "on" bit.
    pub fn insert(self: *Board, piece: *const Piece, x: usize, y: usize, next_check_maybe_ok: ?*usize) BoardErr!void {
        const Local = struct {
            pub fn check(eSelf: Elem, ePiece: Elem) ?BoardErr {
                if (eSelf & ePiece > 0) {
                    return BoardErr.InsertCollision;
                }
                return null;
            }
            pub fn action(eSelf: Elem, ePiece: Elem) Elem {
                return eSelf | ePiece;
            }
        };

        return iterateCheckAndApply(self, piece, x, y, BoardErr, Local.check, Local.action, next_check_maybe_ok);
    }

    pub fn remove(self: *Board, piece: *const Piece, x: usize, y: usize) BoardErr!void {
        const Local = struct {
            pub fn check(eSelf: Elem, ePiece: Elem) ?BoardErr {
                if (~eSelf & ePiece > 0) {
                    return BoardErr.RemoveMismatch;
                }
                return null;
            }
            pub fn action(eSelf: Elem, ePiece: Elem) Elem {
                return eSelf & ~ePiece;
            }
        };

        return iterateCheckAndApply(self, piece, x, y, BoardErr, Local.check, Local.action, null);
    }
};

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
    const actual = try std.fmt.allocPrint(allocator, "{f}", .{board.current});
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
    const actual = try std.fmt.allocPrint(allocator, "{f}", .{board.current});
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
    const actual = try std.fmt.allocPrint(allocator, "{f}", .{rotated.store});
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(exp, actual);
}
