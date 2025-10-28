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

const Placement = struct {
    x: usize,
    y: usize,
    piece_index: usize,
    rotation_index: usize,
    type_index: usize,
};

const Solution = []Placement;

const State = struct {
    stack: Solution,
    pieces_placed: usize,

    next_index: usize,
    next_rotation_index: usize,
    n_type_placed: usize,

    next_x: usize,
    next_y: usize,
};

const SolverEnd = error{End};

const Solver = struct {
    pieces: []PieceInstance,
    state: State,

    const SolverStates = enum {
        try_placement,
        move_forward_x,
        move_next_row,
        next_rotation,
        accept_piece,
        backtrack,
        saveSolution,
        end,
    };

    fn init(allocator: std.mem.Allocator, pieces: []PieceInstance) !Solver {
        var tot_pieces_tmp: usize = 0;
        for (pieces) |piece| {
            tot_pieces_tmp += piece.mult;
        }
        const stack = try allocator.alloc(Placement, tot_pieces_tmp);
        return Solver{ .pieces = pieces, .state = State{
            .stack = stack,
            .pieces_placed = 0,
            .next_index = 0,
            .next_rotation_index = 0,
            .n_type_placed = 0,
            .next_x = 0,
            .next_y = 0,
        } };
    }

    fn tot_pieces(self: *const Solver) usize {
        return self.state.stack.len;
    }

    fn backtrack(self: *Solver) SolverEnd!void {
        var state = &self.state;
        if (state.pieces_placed == 0) {
            return SolverEnd.End;
        }

        state.pieces_placed -= 1;
        state.next_index = state.stack[state.pieces_placed].piece_index;
        state.next_rotation_index = state.stack[state.pieces_placed].rotation_index;
        state.n_type_placed = state.stack[state.pieces_placed].type_index;
        state.next_x = state.stack[state.pieces_placed].x;
        state.next_y = state.stack[state.pieces_placed].y;
    }

    fn loadNextRotation(self: *Solver) SolverEnd!void {
        var state = &self.state;
        state.next_rotation_index += 1;
        if (state.next_rotation_index >= self.pieces[state.next_index].p.len) {
            return SolverEnd.End;
        }
    }

    fn loadNextPiece(self: *Solver) SolverEnd!void {
        const lastPiecePlaced = self.state.stack[self.state.pieces_placed - 1];
        const lastPlacedType = self.pieces[lastPiecePlaced.piece_index];
        var state = &self.state;
        if (state.n_type_placed < lastPlacedType.mult) {
            // There are more pieces of the same type to be used.
            // Reset rotation to first one and place piece right after the previous one.
            // This makes search a bit more efficient and removes duplicates coming from
            // permutation of pieces of the same type.
            state.next_x = lastPiecePlaced.x + 1;
            state.next_y = lastPiecePlaced.y;
            state.next_rotation_index = 0;
            return;
        } else {
            if (state.pieces_placed == self.tot_pieces()) {
                // Got to the end, we got a solution!
                return SolverEnd.End;
            } else {
                // Need to move to the next type of piece.
                // Reset basically everything
                state.next_index += 1;
                state.next_rotation_index = 0;
                state.n_type_placed = 0;
                state.next_x = 0;
                state.next_y = 0;
            }
        }
    }

    fn acceptPiece(self: *Solver) void {
        var state = &self.state;
        state.stack[state.pieces_placed] = Placement{
            .piece_index = state.next_index,
            .rotation_index = state.next_rotation_index,
            .type_index = state.n_type_placed,
            .x = state.next_x,
            .y = state.next_y,
        };
        state.pieces_placed += 1;
        state.n_type_placed += 1;
    }

    fn nextPiece(self: *const Solver) *b.Piece {
        return &self.pieces[self.state.next_index].p[self.state.next_rotation_index];
    }

    fn solve(self: *Solver, allocator: std.mem.Allocator, board_width: usize, board_height: usize) ![]Solution {
        var board = try b.Board.init(allocator, board_width, board_height);
        defer board.deinit(allocator);
        var solutions = try std.ArrayList(Solution).initCapacity(allocator, 1);
        errdefer solutions.deinit(allocator);

        var machine_state = SolverStates.try_placement;
        loop: while (true) {
            switch (machine_state) {
                SolverStates.try_placement => {
                    const result = board.insert(self.nextPiece(), self.state.next_x, self.state.next_y);
                    if (result) |_| {
                        machine_state = SolverStates.accept_piece;
                    } else |err| {
                        switch (err) {
                            b.BoardErr.InsertCollision => {
                                machine_state = SolverStates.move_forward_x;
                            },
                            b.BoardErr.WidthOverflow => {
                                machine_state = SolverStates.move_next_row;
                            },
                            else => {
                                machine_state = SolverStates.next_rotation;
                            },
                        }
                    }
                },
                SolverStates.accept_piece => {
                    self.acceptPiece();
                    const load_next_result = self.loadNextPiece();
                    if (load_next_result) |_| {
                        machine_state = SolverStates.try_placement;
                    } else |_| {
                        machine_state = SolverStates.saveSolution;
                    }
                },
                SolverStates.saveSolution => {
                    const sol_save = try allocator.alloc(Placement, self.state.stack.len);
                    @memcpy(sol_save, self.state.stack);
                    try solutions.append(allocator, sol_save);
                    machine_state = SolverStates.backtrack;
                },
                SolverStates.move_forward_x => {
                    self.state.next_x += 1;
                    machine_state = SolverStates.try_placement;
                },
                SolverStates.move_next_row => {
                    self.state.next_x = 0;
                    self.state.next_y += 1;
                    machine_state = SolverStates.try_placement;
                },
                SolverStates.next_rotation => {
                    const next_rotation_result = self.loadNextRotation();
                    if (next_rotation_result) |_| {
                        machine_state = SolverStates.try_placement;
                    } else |_| {
                        machine_state = SolverStates.backtrack;
                    }
                },
                SolverStates.backtrack => {
                    const backtrack_result = self.backtrack();
                    if (backtrack_result) |_| {
                        board.remove(&self.pieces[self.state.next_index].p[self.state.next_rotation_index], self.state.next_x, self.state.next_y) catch unreachable;
                        machine_state = SolverStates.move_forward_x;
                    } else |_| {
                        machine_state = SolverStates.end;
                    }
                },
                SolverStates.end => break :loop,
            }
        }
        return solutions.toOwnedSlice(allocator);
    }
};

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

test "Solve 4 squares in 4x4 board" {
    const allocator = std.testing.allocator;

    // 1. Define the piece: a 2x2 square
    const square_str =
        \\11
        \\11
    ;
    const piece_input = [_]PieceInput{
        .{ .s = square_str, .mult = 4 },
    };

    // 2. Initialize pieces
    const pieces = try initPieces(allocator, &piece_input, .{});
    defer {
        for (pieces) |*p| {
            p.deinit(allocator);
        }
        allocator.free(pieces);
    }

    // 3. Initialize solver
    var solver = try Solver.init(allocator, pieces);
    defer allocator.free(solver.state.stack);

    // 4. Solve the puzzle
    const solutions = try solver.solve(allocator, 4, 4);
    defer {
        for (solutions) |sol| {
            allocator.free(sol);
        }
        allocator.free(solutions);
    }

    // 5. Check that exactly one solution is found
    try std.testing.expectEqual(1, solutions.len);
}

test "Solve 3 squares in 4x4 board" {
    const allocator = std.testing.allocator;

    // 1. Define the piece: a 2x2 square
    const square_str =
        \\11
        \\11
    ;
    const piece_input = [_]PieceInput{
        .{ .s = square_str, .mult = 3 },
    };

    // 2. Initialize pieces
    const pieces = try initPieces(allocator, &piece_input, .{});
    defer {
        for (pieces) |*p| {
            p.deinit(allocator);
        }
        allocator.free(pieces);
    }

    // 3. Initialize solver
    var solver = try Solver.init(allocator, pieces);
    defer allocator.free(solver.state.stack);

    // 4. Solve the puzzle
    const solutions = try solver.solve(allocator, 4, 4);
    defer {
        for (solutions) |sol| {
            allocator.free(sol);
        }
        allocator.free(solutions);
    }

    // 5. Check that exactly one solution is found
    try std.testing.expectEqual(8, solutions.len);
}

test "Solve 3 squares in 2x2 board" {
    const allocator = std.testing.allocator;

    // 1. Define the piece: a 2x2 square
    const square_str =
        \\1
    ;
    const piece_input = [_]PieceInput{
        .{ .s = square_str, .mult = 3 },
    };

    // 2. Initialize pieces
    const pieces = try initPieces(allocator, &piece_input, .{});
    defer {
        for (pieces) |*p| {
            p.deinit(allocator);
        }
        allocator.free(pieces);
    }

    // 3. Initialize solver
    var solver = try Solver.init(allocator, pieces);
    defer allocator.free(solver.state.stack);

    // 4. Solve the puzzle
    const solutions = try solver.solve(allocator, 2, 2);
    defer {
        for (solutions) |sol| {
            allocator.free(sol);
        }
        allocator.free(solutions);
    }

    // 5. Check that exactly one solution is found
    try std.testing.expectEqual(3, solutions.len);
}
