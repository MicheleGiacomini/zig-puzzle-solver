const std = @import("std");
const zig_puzzle_solver = @import("zig_puzzle_solver");
const s = @import("solver.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    var allocator = gpa.allocator();

    // 1. Define the piece: a 2x2 square
    // const square_1_str =
    //     \\1
    // ;

    // const square_2_str =
    //     \\11
    //     \\11
    // ;

    // const square_3_str =
    //     \\111
    //     \\111
    //     \\111
    // ;

    // const square_4_str =
    //     \\1111
    //     \\1111
    //     \\1111
    //     \\1111
    // ;

    const square_5_str =
        \\11111
        \\11111
        \\11111
        \\11111
        \\11111
    ;

    const piece_input = [_]s.PieceInput{
        .{ .s = square_5_str, .mult = 8 },
        // .{ .s = square_4_str, .mult = 3 },
        // .{ .s = square_3_str, .mult = 3 },
        // .{ .s = square_2_str, .mult = 3 },
    };

    // 2. Initialize pieces
    const pieces = try s.initPieces(allocator, &piece_input, .{});
    defer {
        for (pieces) |*p| {
            p.deinit(allocator);
        }
        allocator.free(pieces);
    }

    // 3. Initialize solver
    var solver = try s.Solver.init(allocator, pieces);
    defer allocator.free(solver.state.stack);

    // 4. Solve the puzzle
    const solutions = try solver.solve(allocator, 15, 15);
    defer {
        for (solutions.solutions) |sol| {
            allocator.free(sol);
        }
        allocator.free(solutions.solutions);
    }

    var stdout_buffer: [1024]u8 = undefined;

    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("{f}", .{solutions});
    // for (solutions.solutions) |sol| {
    //     try stdout.print("{any}\n", .{sol});
    // }
    try stdout.flush();
}
