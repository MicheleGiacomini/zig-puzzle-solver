const std = @import("std");
const assert = std.debug.assert;
const b = @import("board.zig");
const bf = @import("bitfield.zig");

const SolverError = error{
    MultiplicityZero,
};

fn initPiece(allocator: std.mem.Allocator, s: []const u8, config: bf.Bitfield.FromStringConfig) ![]b.Piece {
    var tmp = try std.ArrayList(b.Piece).initCapacity(allocator, 1);
    defer tmp.deinit(allocator);
    errdefer {
        for (tmp.items) |*p| {
            p.deinit(allocator);
        }
    }
    const first = try b.Piece.initFromString(allocator, s, config);
    try tmp.append(allocator, first);
    var i: usize = 0;
    var current = first;
    while (i < 3) : (i += 1) {
        current = try current.rotate(allocator);
        if (current.equal(&first)) {
            current.deinit(allocator);
            break;
        }
        try tmp.append(allocator, current);
    }
    return tmp.toOwnedSlice(allocator);
}

pub const PieceInput = struct {
    /// String representation of the piece
    s: []const u8,
    /// Number of pieces of this type to use
    mult: usize,
};

pub const PieceInstance = struct {
    /// All possible 90 degree rotations of the piece (deduped in case of symmetries)
    p: []b.Piece,
    /// The number of pieces to use
    mult: usize,

    pub fn deinit(self: *PieceInstance, allocator: std.mem.Allocator) void {
        for (self.p) |*pp| {
            pp.deinit(allocator);
        }
        allocator.free(self.p);
    }
};

pub fn initPieces(allocator: std.mem.Allocator, input: []const PieceInput, config: bf.Bitfield.FromStringConfig) ![]PieceInstance {
    var tmp = try std.ArrayList(PieceInstance).initCapacity(allocator, 1);
    defer tmp.deinit(allocator);
    errdefer {
        for (tmp.items) |*p| {
            p.deinit(allocator);
        }
    }
    for (input) |current| {
        if (current.mult == 0) {
            return SolverError.MultiplicityZero;
        }
        const current_piece = try initPiece(allocator, current.s, config);
        var found = false;
        var i: usize = 0;
        itm: for (tmp.items) |other| {
            for (other.p) |compare| {
                if (current_piece[0].equal(&compare)) {
                    found = true;
                    break :itm;
                }
            }
            i += 1;
        }
        if (!found) {
            try tmp.append(allocator, PieceInstance{ .p = current_piece, .mult = current.mult });
        } else {
            for (current_piece) |*p| {
                p.deinit(allocator);
            }
            allocator.free(current_piece);
            tmp.items[i].mult += current.mult;
        }
    }

    return tmp.toOwnedSlice(allocator);
}

test "InitPieces" {
    const s0 =
        \\000
        \\001
    ;
    const m0 = 1;
    const s1 =
        \\100
        \\001
    ;
    const m1 = 1;
    const s2 = s1;
    const m2 = 1;

    const allocator = std.testing.allocator;
    const p0 = PieceInput{
        .s = s0,
        .mult = m0,
    };
    const p1 = PieceInput{
        .s = s1,
        .mult = m1,
    };
    const p2 = PieceInput{
        .s = s2,
        .mult = m2,
    };
    const arg: [3]PieceInput = .{ p0, p1, p2 };
    const pieces = try initPieces(allocator, &arg, .{});
    defer allocator.free(pieces);
    defer {
        for (pieces) |*p| {
            p.deinit(allocator);
        }
    }
    try std.testing.expectEqual(2, pieces.len);
}
