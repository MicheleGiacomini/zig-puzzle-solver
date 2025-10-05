const bf = @import("bitfield.zig");
const std = @import("std");
const assert = std.debug.assert;

const Piece = struct {
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
        const b = try bf.Bitfield.initFromString(allocator, s, config);
        return Piece{
            .store = b,
            .width = b.width,
            .height = b.height,
        };
    }

    pub fn deinit(self: *Piece, allocator: std.mem.Allocator) void {
        self.store.deinit(allocator);
    }
};

const BoardErr = error{InsertCollision};

const Board = struct {
    current: bf.Bitfield,
    buf: bf.Bitfield,
    width: usize,
    height: usize,

    const Elem = bf.Bitfield.Elem;
    const elem_bit_width = bf.Bitfield.elem_bit_width;
    const max_elem = bf.Bitfield.max_elem;

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Board {
        const current = try bf.Bitfield.init(allocator, width, height);
        const buf = try bf.Bitfield.init(allocator, width, height);
        return Board{
            .current = current,
            .buf = buf,
            .width = width,
            .height = height,
        };
    }

    pub fn initFromString(allocator: std.mem.Allocator, s: []const u8, config: bf.FromStringConfig) !Board {
        const current = try bf.Bitfield.initFromString(allocator, s, config);
        const buf = try bf.Bitfield.init(allocator, current.width, current.height);
        return Board{
            .current = current,
            .buf = buf,
            .width = current.width,
            .height = current.height,
        };
    }

    pub fn deinit(self: *Board, allocator: std.mem.Allocator) void {
        self.current.deinit(allocator);
        self.buf.deinit(allocator);
    }

    fn iterateCheckAndApply(self: *Board, piece: *const Piece, x: usize, y: usize, comptime err: type, comptime check: ?*const fn (Elem, Elem) ?err, comptime action: *const fn (Elem, Elem) Elem) err!void {
        assert(piece.height + y <= self.height);
        assert(piece.width + x <= self.width);

        var piece_elem_index: usize = 0;

        @memcpy(self.buf.data, self.current.data);

        while (piece_elem_index < piece.store.data.len) : (piece_elem_index += 1) {
            var piece_elem_offset: usize = 0;
            var inner_iter_count: usize = 0;
            while (piece_elem_offset < elem_bit_width) : (inner_iter_count += 1) {
                assert(inner_iter_count <= elem_bit_width);
                const piece_total_offset = piece_elem_index * piece.width + piece_elem_offset;
                const piece_line = @divTrunc(piece_total_offset, piece.width);
                const piece_line_offset = @mod(piece_total_offset, piece.width);
                if (piece_line >= piece.height) {
                    break;
                }
                const board_line = piece_line + y;
                const board_line_offset = piece_line_offset + x;
                const board_total_offset = board_line * self.width + board_line_offset;
                const board_elem_offset = @mod(board_total_offset, elem_bit_width);
                const board_elem_index = @divTrunc(board_total_offset, elem_bit_width);

                const available_read_bits = @min(piece.width - piece_line_offset, elem_bit_width - piece_elem_offset, self.width - board_line_offset, elem_bit_width - board_elem_offset);
                const piece_mask = max_elem >> @intCast(piece_elem_offset) & max_elem << @intCast(elem_bit_width - piece_elem_offset - available_read_bits);
                const board_mask = max_elem >> @intCast(board_elem_offset) & max_elem << @intCast(elem_bit_width - board_elem_offset - available_read_bits);

                const piece_bits = piece.store.data[piece_elem_index] & piece_mask;
                const board_write_bits = blk: {
                    if (piece_elem_offset > board_elem_offset) {
                        break :blk piece_bits << @intCast(piece_elem_offset - board_elem_offset);
                    } else {
                        break :blk piece_bits >> @intCast(board_elem_offset - piece_elem_offset);
                    }
                };
                const board_write_to_region = self.buf.data[board_elem_index] & board_mask;
                if (check) |c| {
                    const check_result = c(board_write_to_region, board_write_bits);
                    if (check_result) |e| {
                        return e;
                    }
                }
                self.buf.data[board_elem_index] = (self.buf.data[board_elem_index] & (~board_mask)) | (action(board_write_to_region, board_write_bits));
                piece_elem_offset += available_read_bits;
            }
        }
        const current = self.current;
        self.current = self.buf;
        self.buf = current;
    }

    fn iterateAndApply(self: *Board, piece: *const Piece, x: usize, y: usize, action: *const fn (u64, u64) u64) void {
        iterateCheckAndApply(self, piece, x, y, void, null, action) catch unreachable;
    }

    /// Takes a smaller bitfield and inserts it at offset in self. Returns an error if self & other has any "on" bit.
    pub fn insert(self: *Board, piece: *const Piece, x: usize, y: usize) BoardErr!void {
        const Local = struct {
            pub fn insertCeck(eSelf: Elem, ePiece: Elem) ?BoardErr {
                if (eSelf & ePiece > 0) {
                    return BoardErr.InsertCollision;
                }
                return null;
            }
            pub fn action(eSelf: Elem, ePiece: Elem) Elem {
                return eSelf | ePiece;
            }
        };

        return iterateCheckAndApply(self, piece, x, y, BoardErr, Local.insertCeck, Local.action);
    }
};

test "Insert piece no collision" {
    const s =
        \\010
        \\111
    ;

    const exp =
        \\0000000000
        \\0000000000
        \\0000000000
        \\0000100000
        \\0001110000
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
    try board.insert(&piece, 3, 3);
    const actual = try std.fmt.allocPrint(allocator, "{f}", .{board.current});
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(exp, actual);
}

test "Insert piece no collision across element boundaries" {
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
        \\0001000000
        \\0011100000
        \\0000000000
        \\0000000000
        \\0000000000
    ;
    const allocator = std.testing.allocator;
    var piece = try Piece.initFromString(allocator, s, .{});
    defer piece.deinit(allocator);
    var board = try Board.init(allocator, 10, 10);
    defer board.deinit(allocator);
    try board.insert(&piece, 2, 5);
    const actual = try std.fmt.allocPrint(allocator, "{f}", .{board.current});
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(exp, actual);
}
