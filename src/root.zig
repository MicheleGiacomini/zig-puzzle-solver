// Export solver types and functions
const solver = @import("solver.zig");
pub const PieceInput = solver.PieceInput;
pub const PieceInstance = solver.PieceInstance;
pub const initPieces = solver.initPieces;
pub const Solver = solver.Solver;
pub const SolverError = solver.SolverError;

// Export board types and functions
const board = @import("board.zig");
pub const Piece = board.Piece;
pub const Board = board.Board;
pub const BoardErr = board.BoardErr;

// Export bitfield types and functions
const bitfield = @import("bitfield.zig");
pub const Bitfield = bitfield.Bitfield;

// This test ensures all imported modules' tests are included when testing root.zig
test {
    // Reference the imports to ensure their tests are included
    _ = solver;
    _ = board;
    _ = bitfield;
}
