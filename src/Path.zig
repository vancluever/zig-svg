const std = @import("std");
const debug = @import("std").debug;
const fmt = @import("std").fmt;
const heap = @import("std").heap;
const io = @import("std").io;
const log = @import("std").log;
const mem = @import("std").mem;
const testing = @import("std").testing;

const Path = @This();

// All parsed items are stored in the arena, e.g., any ArrayLists that we use
// to build multi-arg nodes use this arena as a backing store. deinit clears
// the arena.
arena: heap.ArenaAllocator,

data: []const u8,
filename: []const u8,
line_pos: usize,
pos: usize = 0,

err: ?ParseError = null,

const ParseError = struct {
    expected: Expected,
    pos: Pos,

    const Expected = enum {
        A_or_a,
        C_or_c,
        H_or_h,
        L_or_l,
        M_or_m,
        Q_or_q,
        S_or_s,
        T_or_t,
        V_or_v,
        Z_or_z,
        coordinate_pair,
        drawto_command,
        flag,
        moveto_command,
        nonnegative_number,
        number,
    };

    fn init(expected: Expected, pos: Pos) ParseError {
        return .{
            .expected = expected,
            .pos = pos,
        };
    }
};

pub fn init(alloc: mem.Allocator, filename: []const u8, line_pos: usize, data: []const u8) Path {
    return .{
        .arena = heap.ArenaAllocator.init(alloc),
        .filename = filename,
        .line_pos = line_pos,
        .data = data,
    };
}

pub fn deinit(self: *Path) void {
    self.arena.deinit();
}

fn setErr(self: *Path, expected: ParseError.Expected, start: usize, end: usize, reset: usize) void {
    self.err = ParseError.init(expected, .{ .start = start, .end = end });
    self.pos = reset;
}

pub fn fmtErr(self: *Path, writer: anytype) !void {
    if (self.err) |e| {
        try fmt.format(
            writer,
            "at {s}:{d}:{d}: expected {s}, found ",
            .{
                self.filename,
                self.line_pos,
                if (e.pos.start < self.data.len) e.pos.start + 1 else self.data.len,
                @tagName(e.expected),
            },
        );
        if (e.pos.start < self.data.len) {
            try fmt.format(writer, "'{s}'\n", .{self.data[e.pos.start .. e.pos.end + 1]});
        } else {
            try fmt.format(writer, "end of path data\n", .{});
        }
    }
}

/// The character position in the data for a particular element, zero indexed.
///
/// Note that reported positions include line breaks and are 1-indexed.
pub const Pos = struct {
    start: usize,
    end: usize,
};

pub const HorizontalLineTo = struct {
    relative: bool,
    args: []Number,
    pos: Pos,

    fn parse(self: *Path) !?HorizontalLineTo {
        const reset = self.pos;
        var start = self.pos;
        var relative: bool = undefined;
        var pos: Pos = undefined;
        var args = std.ArrayList(Number).init(self.arena.allocator());
        errdefer args.deinit();

        switch (self.data[self.pos]) {
            'H' => relative = false,
            'h' => relative = true,
            else => {
                self.setErr(.H_or_h, start, self.pos, reset);
                args.deinit();
                return null;
            },
        }

        pos.start = self.pos;
        pos.end = self.pos;
        self.pos += 1;
        self.consumeWhitespace();

        start = self.pos;
        if (Number.parse(self)) |a| {
            try args.append(a);
            pos.end = a.pos.end;
        } else {
            self.setErr(.number, start, self.pos, reset);
            args.deinit();
            return null;
        }

        start = self.pos;
        self.consumeCommaWhitespace();
        while (Number.parse(self)) |a| {
            try args.append(a);
            pos.end = a.pos.end;
            start = self.pos;
            self.consumeCommaWhitespace();
        }

        // Rewind to right after the end of last good consumed sequence, and
        // clear any errors
        self.pos = start;
        self.err = null;
        return .{
            .relative = relative,
            .args = args.items,
            .pos = pos,
        };
    }
};

pub const VerticalLineTo = struct {
    relative: bool,
    args: []Number,
    pos: Pos,

    fn parse(self: *Path) !?VerticalLineTo {
        const reset = self.pos;
        var start = self.pos;
        var relative: bool = undefined;
        var pos: Pos = undefined;
        var args = std.ArrayList(Number).init(self.arena.allocator());
        errdefer args.deinit();

        switch (self.data[self.pos]) {
            'V' => relative = false,
            'v' => relative = true,
            else => {
                self.setErr(.V_or_v, start, self.pos, reset);
                args.deinit();
                return null;
            },
        }

        pos.start = self.pos;
        pos.end = self.pos;
        self.pos += 1;
        self.consumeWhitespace();

        start = self.pos;
        if (Number.parse(self)) |a| {
            try args.append(a);
            pos.end = a.pos.end;
        } else {
            self.setErr(.number, start, self.pos, reset);
            args.deinit();
            return null;
        }

        start = self.pos;
        self.consumeCommaWhitespace();
        while (Number.parse(self)) |a| {
            try args.append(a);
            pos.end = a.pos.end;
            start = self.pos;
            self.consumeCommaWhitespace();
        }

        // Rewind to right after the end of last good consumed sequence, and
        // clear any errors
        self.pos = start;
        self.err = null;
        return .{
            .relative = relative,
            .args = args.items,
            .pos = pos,
        };
    }
};

pub const CurveTo = struct {
    relative: bool,
    args: []CurveToArgument,
    pos: Pos,

    fn parse(self: *Path) !?CurveTo {
        const reset = self.pos;
        var start = self.pos;
        var relative: bool = undefined;
        var pos: Pos = undefined;
        var args = std.ArrayList(CurveToArgument).init(self.arena.allocator());
        errdefer args.deinit();

        switch (self.data[self.pos]) {
            'C' => relative = false,
            'c' => relative = true,
            else => {
                self.setErr(.C_or_c, start, self.pos, reset);
                args.deinit();
                return null;
            },
        }

        pos.start = self.pos;
        pos.end = self.pos;
        self.pos += 1;
        self.consumeWhitespace();

        start = self.pos;
        if (CurveToArgument.parse(self)) |a| {
            try args.append(a);
            pos.end = a.pos.end;
        } else {
            debug.assert(self.err != null);
            // Error has already been set, but we need to reset our position
            self.pos = reset;
            args.deinit();
            return null;
        }

        start = self.pos;
        self.consumeCommaWhitespace();
        while (CurveToArgument.parse(self)) |a| {
            try args.append(a);
            pos.end = a.pos.end;
            start = self.pos;
            self.consumeCommaWhitespace();
        }

        // Rewind to right after the end of last good consumed sequence, and
        // clear any errors
        self.pos = start;
        self.err = null;
        return .{
            .relative = relative,
            .args = args.items,
            .pos = pos,
        };
    }
};

pub const CurveToArgument = struct {
    p1: CoordinatePair,
    p2: CoordinatePair,
    end: CoordinatePair,
    pos: Pos,

    fn parse(self: *Path) ?CurveToArgument {
        const reset = self.pos;
        var result: CurveToArgument = undefined;
        if (CoordinatePair.parse(self)) |p| {
            result.p1 = p;
            result.pos = p.pos;
        } else {
            debug.assert(self.err != null);
            // Error has already been set, but we need to reset our position
            self.pos = reset;
            return null;
        }

        self.consumeCommaWhitespace();

        if (CoordinatePair.parse(self)) |p| {
            result.p2 = p;
            result.pos.end = p.pos.end;
        } else {
            debug.assert(self.err != null);
            // Error has already been set, but we need to reset our position
            self.pos = reset;
            return null;
        }

        self.consumeCommaWhitespace();

        if (CoordinatePair.parse(self)) |p| {
            result.end = p;
            result.pos.end = p.pos.end;
        } else {
            debug.assert(self.err != null);
            // Error has already been set, but we need to reset our position
            self.pos = reset;
            return null;
        }

        return result;
    }
};

pub const SmoothCurveTo = struct {
    relative: bool,
    args: []SmoothCurveToArgument,
    pos: Pos,

    fn parse(self: *Path) !?SmoothCurveTo {
        const reset = self.pos;
        var start = self.pos;
        var relative: bool = undefined;
        var pos: Pos = undefined;
        var args = std.ArrayList(SmoothCurveToArgument).init(self.arena.allocator());
        errdefer args.deinit();

        switch (self.data[self.pos]) {
            'S' => relative = false,
            's' => relative = true,
            else => {
                self.setErr(.S_or_s, start, self.pos, reset);
                args.deinit();
                return null;
            },
        }

        pos.start = self.pos;
        pos.end = self.pos;
        self.pos += 1;
        self.consumeWhitespace();

        start = self.pos;
        if (SmoothCurveToArgument.parse(self)) |a| {
            try args.append(a);
            pos.end = a.pos.end;
        } else {
            debug.assert(self.err != null);
            // Error has already been set, but we need to reset our position
            self.pos = reset;
            args.deinit();
            return null;
        }

        start = self.pos;
        self.consumeCommaWhitespace();
        while (SmoothCurveToArgument.parse(self)) |a| {
            try args.append(a);
            pos.end = a.pos.end;
            start = self.pos;
            self.consumeCommaWhitespace();
        }

        // Rewind to right after the end of last good consumed sequence, and
        // clear any errors
        self.pos = start;
        self.err = null;
        return .{
            .relative = relative,
            .args = args.items,
            .pos = pos,
        };
    }
};

pub const SmoothCurveToArgument = struct {
    p2: CoordinatePair,
    end: CoordinatePair,
    pos: Pos,

    fn parse(self: *Path) ?SmoothCurveToArgument {
        const reset = self.pos;
        var result: SmoothCurveToArgument = undefined;
        if (CoordinatePair.parse(self)) |p| {
            result.p2 = p;
            result.pos = p.pos;
        } else {
            debug.assert(self.err != null);
            // Error has already been set, but we need to reset our position
            self.pos = reset;
            return null;
        }

        self.consumeCommaWhitespace();

        if (CoordinatePair.parse(self)) |p| {
            result.end = p;
            result.pos.end = p.pos.end;
        } else {
            debug.assert(self.err != null);
            // Error has already been set, but we need to reset our position
            self.pos = reset;
            return null;
        }

        return result;
    }
};

pub const QuadraticBezierCurveTo = struct {
    relative: bool,
    args: []QuadraticBezierCurveToArgument,
    pos: Pos,

    fn parse(self: *Path) !?QuadraticBezierCurveTo {
        const reset = self.pos;
        var start = self.pos;
        var relative: bool = undefined;
        var pos: Pos = undefined;
        var args = std.ArrayList(QuadraticBezierCurveToArgument).init(self.arena.allocator());
        errdefer args.deinit();

        switch (self.data[self.pos]) {
            'Q' => relative = false,
            'q' => relative = true,
            else => {
                self.setErr(.Q_or_q, start, self.pos, reset);
                args.deinit();
                return null;
            },
        }

        pos.start = self.pos;
        pos.end = self.pos;
        self.pos += 1;
        self.consumeWhitespace();

        start = self.pos;
        if (QuadraticBezierCurveToArgument.parse(self)) |a| {
            try args.append(a);
            pos.end = a.pos.end;
        } else {
            debug.assert(self.err != null);
            // Error has already been set, but we need to reset our position
            self.pos = reset;
            args.deinit();
            return null;
        }

        start = self.pos;
        self.consumeCommaWhitespace();
        while (QuadraticBezierCurveToArgument.parse(self)) |a| {
            try args.append(a);
            pos.end = a.pos.end;
            start = self.pos;
            self.consumeCommaWhitespace();
        }

        // Rewind to right after the end of last good consumed sequence, and
        // clear any errors
        self.pos = start;
        self.err = null;
        return .{
            .relative = relative,
            .args = args.items,
            .pos = pos,
        };
    }
};

pub const QuadraticBezierCurveToArgument = struct {
    p1: CoordinatePair,
    end: CoordinatePair,
    pos: Pos,

    fn parse(self: *Path) ?QuadraticBezierCurveToArgument {
        const reset = self.pos;
        var result: QuadraticBezierCurveToArgument = undefined;
        if (CoordinatePair.parse(self)) |p| {
            result.p1 = p;
            result.pos = p.pos;
        } else {
            debug.assert(self.err != null);
            // Error has already been set, but we need to reset our position
            self.pos = reset;
            return null;
        }

        self.consumeCommaWhitespace();

        if (CoordinatePair.parse(self)) |p| {
            result.end = p;
            result.pos.end = p.pos.end;
        } else {
            debug.assert(self.err != null);
            // Error has already been set, but we need to reset our position
            self.pos = reset;
            return null;
        }

        return result;
    }
};

pub const SmoothQuadraticBezierCurveTo = struct {
    relative: bool,
    args: []CoordinatePair,
    pos: Pos,

    fn parse(self: *Path) !?SmoothQuadraticBezierCurveTo {
        const reset = self.pos;
        var start = self.pos;
        var relative: bool = undefined;
        var pos: Pos = undefined;
        var args = std.ArrayList(CoordinatePair).init(self.arena.allocator());
        errdefer args.deinit();

        switch (self.data[self.pos]) {
            'T' => relative = false,
            't' => relative = true,
            else => {
                self.setErr(.T_or_t, start, self.pos, reset);
                args.deinit();
                return null;
            },
        }

        pos.start = self.pos;
        pos.end = self.pos;
        self.pos += 1;
        self.consumeWhitespace();

        start = self.pos;
        if (CoordinatePair.parse(self)) |a| {
            try args.append(a);
            pos.end = a.pos.end;
        } else {
            debug.assert(self.err != null);
            // Error has already been set, but we need to reset our position
            self.pos = reset;
            args.deinit();
            return null;
        }

        start = self.pos;
        self.consumeCommaWhitespace();
        while (CoordinatePair.parse(self)) |a| {
            try args.append(a);
            pos.end = a.pos.end;
            start = self.pos;
            self.consumeCommaWhitespace();
        }

        // Rewind to right after the end of last good consumed sequence, and
        // clear any errors
        self.pos = start;
        self.err = null;
        return .{
            .relative = relative,
            .args = args.items,
            .pos = pos,
        };
    }
};

pub const EllipticalArc = struct {
    relative: bool,
    args: []EllipticalArcArgument,
    pos: Pos,

    fn parse(self: *Path) !?EllipticalArc {
        const reset = self.pos;
        var start = self.pos;
        var relative: bool = undefined;
        var pos: Pos = undefined;
        var args = std.ArrayList(EllipticalArcArgument).init(self.arena.allocator());
        errdefer args.deinit();

        switch (self.data[self.pos]) {
            'A' => relative = false,
            'a' => relative = true,
            else => {
                self.setErr(.A_or_a, start, self.pos, reset);
                args.deinit();
                return null;
            },
        }

        pos.start = self.pos;
        pos.end = self.pos;
        self.pos += 1;
        self.consumeWhitespace();

        start = self.pos;
        if (EllipticalArcArgument.parse(self)) |a| {
            try args.append(a);
            pos.end = a.pos.end;
        } else {
            debug.assert(self.err != null);
            // Error has already been set, but we need to reset our position
            self.pos = reset;
            args.deinit();
            return null;
        }

        start = self.pos;
        self.consumeCommaWhitespace();
        while (EllipticalArcArgument.parse(self)) |a| {
            try args.append(a);
            pos.end = a.pos.end;
            start = self.pos;
            self.consumeCommaWhitespace();
        }

        // Rewind to right after the end of last good consumed sequence, and
        // clear any errors
        self.pos = start;
        self.err = null;
        return .{
            .relative = relative,
            .args = args.items,
            .pos = pos,
        };
    }
};

pub const EllipticalArcArgument = struct {
    rx: Number,
    ry: Number,
    x_axis_rotation: Number,
    large_arc_flag: Flag,
    sweep_flag: Flag,
    point: CoordinatePair,
    pos: Pos,

    fn parse(self: *Path) ?EllipticalArcArgument {
        const reset = self.pos;
        var start = self.pos;
        var result: EllipticalArcArgument = undefined;
        if (Number.parse(self)) |n| {
            if (n.value < 0) {
                // Note: we rewind the end point here by 1 as we're asserting
                // on a valid value, so our position is on the next character
                // to be read.
                self.setErr(.nonnegative_number, start, self.pos - 1, reset);
                return null;
            }
            result.rx = n;
            result.pos = n.pos;
        } else {
            self.setErr(.nonnegative_number, start, self.pos, reset);
            return null;
        }

        self.consumeCommaWhitespace();

        start = self.pos;
        if (Number.parse(self)) |n| {
            if (n.value < 0) {
                self.setErr(.nonnegative_number, start, self.pos - 1, reset);
                return null;
            }
            result.ry = n;
            result.pos.end = n.pos.end;
        } else {
            self.setErr(.nonnegative_number, start, self.pos, reset);
            return null;
        }

        self.consumeCommaWhitespace();

        start = self.pos;
        if (Number.parse(self)) |n| {
            result.x_axis_rotation = n;
            result.pos.end = n.pos.end;
        } else {
            self.setErr(.number, start, self.pos, reset);
            return null;
        }

        self.consumeCommaWhitespace();

        start = self.pos;
        if (Flag.parse(self)) |f| {
            result.large_arc_flag = f;
            result.pos.end = f.pos.end;
        } else {
            self.setErr(.flag, start, self.pos, reset);
            return null;
        }

        self.consumeCommaWhitespace();

        start = self.pos;
        if (Flag.parse(self)) |f| {
            result.sweep_flag = f;
            result.pos.end = f.pos.end;
        } else {
            self.setErr(.flag, start, self.pos, reset);
            return null;
        }

        self.consumeCommaWhitespace();

        if (CoordinatePair.parse(self)) |p| {
            result.point = p;
            result.pos.end = p.pos.end;
        } else {
            debug.assert(self.err != null);
            // Error has already been set, but we need to reset our position
            self.pos = reset;
            return null;
        }

        return result;
    }
};

pub const CoordinatePair = struct {
    coordinates: [2]Coordinate,
    pos: Pos,

    fn parse(self: *Path) ?CoordinatePair {
        const reset = self.pos;
        var result: CoordinatePair = undefined;
        if (Coordinate.parse(self)) |c| {
            result.coordinates[0] = c;
            result.pos.start = c.pos.start;
        } else {
            self.setErr(.coordinate_pair, reset, self.pos, reset);
            return null;
        }

        self.consumeCommaWhitespace();

        if (Coordinate.parse(self)) |c| {
            result.coordinates[1] = c;
            result.pos.end = c.pos.end;
        } else {
            self.setErr(
                .coordinate_pair,
                reset,
                if (self.pos < self.data.len) self.pos else self.pos - 1,
                reset,
            );
            return null;
        }

        return result;
    }
};

pub const Coordinate = struct {
    number: Number,
    pos: Pos,

    fn parse(self: *Path) ?Coordinate {
        if (Number.parse(self)) |n| {
            return .{
                .number = n,
                .pos = n.pos,
            };
        }

        return null;
    }
};

pub const Flag = struct {
    value: bool,
    pos: Pos,

    fn parse(self: *Path) ?Flag {
        if (self.pos >= self.data.len) return null;
        return switch (self.data[self.pos]) {
            '0' => ret: {
                const pos = self.pos;
                self.pos += 1;
                break :ret .{
                    .value = false,
                    .pos = .{
                        .start = pos,
                        .end = pos,
                    },
                };
            },
            '1' => ret: {
                const pos = self.pos;
                self.pos += 1;
                break :ret .{
                    .value = true,
                    .pos = .{
                        .start = pos,
                        .end = pos,
                    },
                };
            },
            else => null,
        };
    }
};

pub const Number = struct {
    value: f64, // Actual parsed value with sign and exponent
    pos: Pos,

    fn parse(self: *Path) ?Number {
        var ctx: enum {
            int_invalid,
            int_sign,
            int,
            frac_invalid,
            frac,
            exp_invalid,
            exp_sign,
            exp,
        } = .int_invalid;
        var pos: ?Pos = null;

        while (self.pos < self.data.len) : (self.pos += 1) {
            switch (self.data[self.pos]) {
                '+', '-' => switch (ctx) {
                    .int_invalid => ctx = .int_sign,
                    .exp_invalid => ctx = .exp_sign,
                    else => break,
                },
                '.' => switch (ctx) {
                    .int_invalid, .int_sign, .int => ctx = .frac_invalid,
                    else => break,
                },
                'e', 'E' => switch (ctx) {
                    .int, .frac => ctx = .exp_invalid,
                    else => break,
                },
                '0'...'9' => switch (ctx) {
                    .int_invalid, .int_sign => ctx = .int,
                    .frac_invalid => ctx = .frac,
                    .exp_invalid, .exp_sign => ctx = .exp,
                    .int, .frac, .exp => {},
                },
                else => break,
            }

            if (pos != null) {
                pos.?.end = self.pos;
            } else {
                pos = .{
                    .start = self.pos,
                    .end = self.pos,
                };
            }
        }

        if (pos != null) {
            var p = pos.?;
            switch (ctx) {
                // We need to rewind our position on certain states.
                .int_sign, .frac_invalid, .exp_invalid, .exp_sign => {
                    p.end -= 1;
                    self.pos -= 1;
                },
                else => {},
            }
            if (p.end < p.start) {
                return null;
            }
            const val = fmt.parseFloat(f64, self.data[p.start .. p.end + 1]) catch unreachable;
            return .{
                .value = val,
                .pos = p,
            };
        }

        return null;
    }
};

fn consumeCommaWhitespace(self: *Path) void {
    var hasComma = false;
    while (self.pos < self.data.len) : (self.pos += 1) {
        switch (self.data[self.pos]) {
            0x09 => {},
            0x20 => {},
            0x0a => {},
            0x0c => {},
            0x0d => {},
            ',' => {
                if (hasComma) break;
                hasComma = true;
            },
            else => break,
        }
    }
}

fn consumeWhitespace(self: *Path) void {
    while (self.pos < self.data.len) : (self.pos += 1) {
        switch (self.data[self.pos]) {
            0x09 => {},
            0x20 => {},
            0x0a => {},
            0x0c => {},
            0x0d => {},
            else => break,
        }
    }
}

test "HorizontalLineTo" {
    {
        // Good, single, absolute
        var parser = init(
            testing.allocator,
            "test",
            1,
            "H 10 Z",
        );
        defer parser.deinit();

        const got = try HorizontalLineTo.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(false, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(3, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(3, got.?.pos.end);
        try testing.expectEqual(4, parser.pos);
    }

    {
        // Good, single, relative
        var parser = init(
            testing.allocator,
            "test",
            1,
            "h 10 Z",
        );
        defer parser.deinit();

        const got = try HorizontalLineTo.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(true, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(3, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(3, got.?.pos.end);
        try testing.expectEqual(4, parser.pos);
    }

    {
        // Good, multiple
        var parser = init(
            testing.allocator,
            "test",
            1,
            "H 10 11 12 Z",
        );
        defer parser.deinit();

        const got = try HorizontalLineTo.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(false, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(3, got.?.args[0].pos.end);
        try testing.expectEqual(11, got.?.args[1].value);
        try testing.expectEqual(5, got.?.args[1].pos.start);
        try testing.expectEqual(6, got.?.args[1].pos.end);
        try testing.expectEqual(12, got.?.args[2].value);
        try testing.expectEqual(8, got.?.args[2].pos.start);
        try testing.expectEqual(9, got.?.args[2].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(9, got.?.pos.end);
        try testing.expectEqual(10, parser.pos);
    }

    {
        // Bad, invalid command
        //
        // Note that we assert this on reading the production, but it should
        // never come up in real-world use.
        var parser = init(
            testing.allocator,
            "test",
            1,
            "x 10",
        );
        defer parser.deinit();

        try testing.expectEqual(null, HorizontalLineTo.parse(&parser));
        try testing.expectEqual(.H_or_h, parser.err.?.expected);
        try testing.expectEqual(0, parser.err.?.pos.start);
        try testing.expectEqual(0, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:1: expected H_or_h, found 'x'\n");
    }

    {
        // Bad, incomplete arg
        var parser = init(
            testing.allocator,
            "test",
            1,
            "H ,",
        );
        defer parser.deinit();

        try testing.expectEqual(null, HorizontalLineTo.parse(&parser));
        try testing.expectEqual(.number, parser.err.?.expected);
        try testing.expectEqual(2, parser.err.?.pos.start);
        try testing.expectEqual(2, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:3: expected number, found ','\n");
    }
}

test "VerticalLineTo" {
    {
        // Good, single, absolute
        var parser = init(
            testing.allocator,
            "test",
            1,
            "V 10 Z",
        );
        defer parser.deinit();

        const got = try VerticalLineTo.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(false, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(3, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(3, got.?.pos.end);
        try testing.expectEqual(4, parser.pos);
    }

    {
        // Good, single, relative
        var parser = init(
            testing.allocator,
            "test",
            1,
            "v 10 Z",
        );
        defer parser.deinit();

        const got = try VerticalLineTo.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(true, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(3, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(3, got.?.pos.end);
        try testing.expectEqual(4, parser.pos);
    }

    {
        // Good, multiple
        var parser = init(
            testing.allocator,
            "test",
            1,
            "V 10 11 12 Z",
        );
        defer parser.deinit();

        const got = try VerticalLineTo.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(false, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(3, got.?.args[0].pos.end);
        try testing.expectEqual(11, got.?.args[1].value);
        try testing.expectEqual(5, got.?.args[1].pos.start);
        try testing.expectEqual(6, got.?.args[1].pos.end);
        try testing.expectEqual(12, got.?.args[2].value);
        try testing.expectEqual(8, got.?.args[2].pos.start);
        try testing.expectEqual(9, got.?.args[2].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(9, got.?.pos.end);
        try testing.expectEqual(10, parser.pos);
    }

    {
        // Bad, invalid command
        //
        // Note that we assert this on reading the production, but it should
        // never come up in real-world use.
        var parser = init(
            testing.allocator,
            "test",
            1,
            "x 10",
        );
        defer parser.deinit();

        try testing.expectEqual(null, VerticalLineTo.parse(&parser));
        try testing.expectEqual(.V_or_v, parser.err.?.expected);
        try testing.expectEqual(0, parser.err.?.pos.start);
        try testing.expectEqual(0, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:1: expected V_or_v, found 'x'\n");
    }

    {
        // Bad, incomplete arg
        var parser = init(
            testing.allocator,
            "test",
            1,
            "V ,",
        );
        defer parser.deinit();

        try testing.expectEqual(null, VerticalLineTo.parse(&parser));
        try testing.expectEqual(.number, parser.err.?.expected);
        try testing.expectEqual(2, parser.err.?.pos.start);
        try testing.expectEqual(2, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:3: expected number, found ','\n");
    }
}

test "CurveTo" {
    {
        // Good, single, absolute
        var parser = init(
            testing.allocator,
            "test",
            1,
            "C 10,11 20,21 30,31",
        );
        defer parser.deinit();

        const got = try CurveTo.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(false, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].p1.coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].p1.coordinates[1].number.value);
        try testing.expectEqual(20, got.?.args[0].p2.coordinates[0].number.value);
        try testing.expectEqual(21, got.?.args[0].p2.coordinates[1].number.value);
        try testing.expectEqual(30, got.?.args[0].end.coordinates[0].number.value);
        try testing.expectEqual(31, got.?.args[0].end.coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(18, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(18, got.?.pos.end);
        try testing.expectEqual(19, parser.pos);
    }

    {
        // Good, single, relative
        var parser = init(
            testing.allocator,
            "test",
            1,
            "c 10,11 20,21 30,31 Z",
        );
        defer parser.deinit();

        const got = try CurveTo.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(true, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].p1.coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].p1.coordinates[1].number.value);
        try testing.expectEqual(20, got.?.args[0].p2.coordinates[0].number.value);
        try testing.expectEqual(21, got.?.args[0].p2.coordinates[1].number.value);
        try testing.expectEqual(30, got.?.args[0].end.coordinates[0].number.value);
        try testing.expectEqual(31, got.?.args[0].end.coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(18, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(18, got.?.pos.end);
        try testing.expectEqual(19, parser.pos);
    }

    {
        // Good, multiple
        var parser = init(
            testing.allocator,
            "test",
            1,
            \\C 10,11 20,21 30,31
            \\40,41 50,51 60,61
            \\70,71 80,81 90,91 Z
            ,
        );
        defer parser.deinit();

        const got = try CurveTo.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(false, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].p1.coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].p1.coordinates[1].number.value);
        try testing.expectEqual(20, got.?.args[0].p2.coordinates[0].number.value);
        try testing.expectEqual(21, got.?.args[0].p2.coordinates[1].number.value);
        try testing.expectEqual(30, got.?.args[0].end.coordinates[0].number.value);
        try testing.expectEqual(31, got.?.args[0].end.coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(18, got.?.args[0].pos.end);
        try testing.expectEqual(40, got.?.args[1].p1.coordinates[0].number.value);
        try testing.expectEqual(41, got.?.args[1].p1.coordinates[1].number.value);
        try testing.expectEqual(50, got.?.args[1].p2.coordinates[0].number.value);
        try testing.expectEqual(51, got.?.args[1].p2.coordinates[1].number.value);
        try testing.expectEqual(60, got.?.args[1].end.coordinates[0].number.value);
        try testing.expectEqual(61, got.?.args[1].end.coordinates[1].number.value);
        try testing.expectEqual(20, got.?.args[1].pos.start);
        try testing.expectEqual(36, got.?.args[1].pos.end);
        try testing.expectEqual(70, got.?.args[2].p1.coordinates[0].number.value);
        try testing.expectEqual(71, got.?.args[2].p1.coordinates[1].number.value);
        try testing.expectEqual(80, got.?.args[2].p2.coordinates[0].number.value);
        try testing.expectEqual(81, got.?.args[2].p2.coordinates[1].number.value);
        try testing.expectEqual(90, got.?.args[2].end.coordinates[0].number.value);
        try testing.expectEqual(91, got.?.args[2].end.coordinates[1].number.value);
        try testing.expectEqual(38, got.?.args[2].pos.start);
        try testing.expectEqual(54, got.?.args[2].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(54, got.?.pos.end);
        try testing.expectEqual(55, parser.pos);
    }

    {
        // Bad, invalid command
        //
        // Note that we assert this on reading the production, but it should
        // never come up in real-world use.
        var parser = init(
            testing.allocator,
            "test",
            1,
            "x 10,11 20,21 30,31",
        );
        defer parser.deinit();

        try testing.expectEqual(null, CurveTo.parse(&parser));
        try testing.expectEqual(.C_or_c, parser.err.?.expected);
        try testing.expectEqual(0, parser.err.?.pos.start);
        try testing.expectEqual(0, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:1: expected C_or_c, found 'x'\n");
    }

    {
        // Bad, incomplete arg
        var parser = init(
            testing.allocator,
            "test",
            1,
            "C 10,11 20,Z",
        );
        defer parser.deinit();

        try testing.expectEqual(null, CurveTo.parse(&parser));
        try testing.expectEqual(.coordinate_pair, parser.err.?.expected);
        try testing.expectEqual(8, parser.err.?.pos.start);
        try testing.expectEqual(11, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:9: expected coordinate_pair, found '20,Z'\n");
    }
}

test "SmoothCurveTo" {
    {
        // Good, single, absolute
        var parser = init(
            testing.allocator,
            "test",
            1,
            "S 10,11 20,21",
        );
        defer parser.deinit();

        const got = try SmoothCurveTo.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(false, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].p2.coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].p2.coordinates[1].number.value);
        try testing.expectEqual(20, got.?.args[0].end.coordinates[0].number.value);
        try testing.expectEqual(21, got.?.args[0].end.coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(12, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(12, got.?.pos.end);
        try testing.expectEqual(13, parser.pos);
    }

    {
        // Good, single, relative
        var parser = init(
            testing.allocator,
            "test",
            1,
            "s 10,11 20,21 Z",
        );
        defer parser.deinit();

        const got = try SmoothCurveTo.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(true, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].p2.coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].p2.coordinates[1].number.value);
        try testing.expectEqual(20, got.?.args[0].end.coordinates[0].number.value);
        try testing.expectEqual(21, got.?.args[0].end.coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(12, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(12, got.?.pos.end);
        try testing.expectEqual(13, parser.pos);
    }

    {
        // Good, multiple
        var parser = init(
            testing.allocator,
            "test",
            1,
            \\S 10,11 20,21
            \\30,31 40,41
            \\50,51 60,61 Z
            ,
        );
        defer parser.deinit();

        const got = try SmoothCurveTo.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(false, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].p2.coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].p2.coordinates[1].number.value);
        try testing.expectEqual(20, got.?.args[0].end.coordinates[0].number.value);
        try testing.expectEqual(21, got.?.args[0].end.coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(12, got.?.args[0].pos.end);
        try testing.expectEqual(30, got.?.args[1].p2.coordinates[0].number.value);
        try testing.expectEqual(31, got.?.args[1].p2.coordinates[1].number.value);
        try testing.expectEqual(40, got.?.args[1].end.coordinates[0].number.value);
        try testing.expectEqual(41, got.?.args[1].end.coordinates[1].number.value);
        try testing.expectEqual(14, got.?.args[1].pos.start);
        try testing.expectEqual(24, got.?.args[1].pos.end);
        try testing.expectEqual(50, got.?.args[2].p2.coordinates[0].number.value);
        try testing.expectEqual(51, got.?.args[2].p2.coordinates[1].number.value);
        try testing.expectEqual(60, got.?.args[2].end.coordinates[0].number.value);
        try testing.expectEqual(61, got.?.args[2].end.coordinates[1].number.value);
        try testing.expectEqual(26, got.?.args[2].pos.start);
        try testing.expectEqual(36, got.?.args[2].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(36, got.?.pos.end);
        try testing.expectEqual(37, parser.pos);
    }

    {
        // Bad, invalid command
        //
        // Note that we assert this on reading the production, but it should
        // never come up in real-world use.
        var parser = init(
            testing.allocator,
            "test",
            1,
            "x 10,11 20,21",
        );
        defer parser.deinit();

        try testing.expectEqual(null, SmoothCurveTo.parse(&parser));
        try testing.expectEqual(.S_or_s, parser.err.?.expected);
        try testing.expectEqual(0, parser.err.?.pos.start);
        try testing.expectEqual(0, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:1: expected S_or_s, found 'x'\n");
    }

    {
        // Bad, incomplete arg
        var parser = init(
            testing.allocator,
            "test",
            1,
            "S 10,11 20,Z",
        );
        defer parser.deinit();

        try testing.expectEqual(null, SmoothCurveTo.parse(&parser));
        try testing.expectEqual(.coordinate_pair, parser.err.?.expected);
        try testing.expectEqual(8, parser.err.?.pos.start);
        try testing.expectEqual(11, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:9: expected coordinate_pair, found '20,Z'\n");
    }
}

test "QuadraticBezierCurveTo" {
    {
        // Good, single, absolute
        var parser = init(
            testing.allocator,
            "test",
            1,
            "Q 10,11 20,21",
        );
        defer parser.deinit();

        const got = try QuadraticBezierCurveTo.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(false, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].p1.coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].p1.coordinates[1].number.value);
        try testing.expectEqual(20, got.?.args[0].end.coordinates[0].number.value);
        try testing.expectEqual(21, got.?.args[0].end.coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(12, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(12, got.?.pos.end);
        try testing.expectEqual(13, parser.pos);
    }

    {
        // Good, single, relative
        var parser = init(
            testing.allocator,
            "test",
            1,
            "q 10,11 20,21 Z",
        );
        defer parser.deinit();

        const got = try QuadraticBezierCurveTo.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(true, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].p1.coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].p1.coordinates[1].number.value);
        try testing.expectEqual(20, got.?.args[0].end.coordinates[0].number.value);
        try testing.expectEqual(21, got.?.args[0].end.coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(12, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(12, got.?.pos.end);
        try testing.expectEqual(13, parser.pos);
    }

    {
        // Good, multiple
        var parser = init(
            testing.allocator,
            "test",
            1,
            \\Q 10,11 20,21
            \\30,31 40,41
            \\50,51 60,61 Z
            ,
        );
        defer parser.deinit();

        const got = try QuadraticBezierCurveTo.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(false, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].p1.coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].p1.coordinates[1].number.value);
        try testing.expectEqual(20, got.?.args[0].end.coordinates[0].number.value);
        try testing.expectEqual(21, got.?.args[0].end.coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(12, got.?.args[0].pos.end);
        try testing.expectEqual(30, got.?.args[1].p1.coordinates[0].number.value);
        try testing.expectEqual(31, got.?.args[1].p1.coordinates[1].number.value);
        try testing.expectEqual(40, got.?.args[1].end.coordinates[0].number.value);
        try testing.expectEqual(41, got.?.args[1].end.coordinates[1].number.value);
        try testing.expectEqual(14, got.?.args[1].pos.start);
        try testing.expectEqual(24, got.?.args[1].pos.end);
        try testing.expectEqual(50, got.?.args[2].p1.coordinates[0].number.value);
        try testing.expectEqual(51, got.?.args[2].p1.coordinates[1].number.value);
        try testing.expectEqual(60, got.?.args[2].end.coordinates[0].number.value);
        try testing.expectEqual(61, got.?.args[2].end.coordinates[1].number.value);
        try testing.expectEqual(26, got.?.args[2].pos.start);
        try testing.expectEqual(36, got.?.args[2].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(36, got.?.pos.end);
        try testing.expectEqual(37, parser.pos);
    }

    {
        // Bad, invalid command
        //
        // Note that we assert this on reading the production, but it should
        // never come up in real-world use.
        var parser = init(
            testing.allocator,
            "test",
            1,
            "x 10,11 20,21",
        );
        defer parser.deinit();

        try testing.expectEqual(null, QuadraticBezierCurveTo.parse(&parser));
        try testing.expectEqual(.Q_or_q, parser.err.?.expected);
        try testing.expectEqual(0, parser.err.?.pos.start);
        try testing.expectEqual(0, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:1: expected Q_or_q, found 'x'\n");
    }

    {
        // Bad, incomplete arg
        var parser = init(
            testing.allocator,
            "test",
            1,
            "Q 10,11 20,Z",
        );
        defer parser.deinit();

        try testing.expectEqual(null, QuadraticBezierCurveTo.parse(&parser));
        try testing.expectEqual(.coordinate_pair, parser.err.?.expected);
        try testing.expectEqual(8, parser.err.?.pos.start);
        try testing.expectEqual(11, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:9: expected coordinate_pair, found '20,Z'\n");
    }
}

test "SmoothQuadraticBezierCurveTo" {
    {
        // Good, single, absolute
        var parser = init(
            testing.allocator,
            "test",
            1,
            "T 10,11 Z",
        );
        defer parser.deinit();

        const got = try SmoothQuadraticBezierCurveTo.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(false, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(6, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(6, got.?.pos.end);
        try testing.expectEqual(7, parser.pos);
    }

    {
        // Good, single, relative
        var parser = init(
            testing.allocator,
            "test",
            1,
            "t 10,11 Z",
        );
        defer parser.deinit();

        const got = try SmoothQuadraticBezierCurveTo.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(true, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(6, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(6, got.?.pos.end);
        try testing.expectEqual(7, parser.pos);
    }

    {
        // Good, multiple
        var parser = init(
            testing.allocator,
            "test",
            1,
            "T 10,11 20,21 30,31 Z",
        );
        defer parser.deinit();

        const got = try SmoothQuadraticBezierCurveTo.parse(&parser);
        try testing.expectEqual(false, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(6, got.?.args[0].pos.end);
        try testing.expectEqual(20, got.?.args[1].coordinates[0].number.value);
        try testing.expectEqual(21, got.?.args[1].coordinates[1].number.value);
        try testing.expectEqual(8, got.?.args[1].pos.start);
        try testing.expectEqual(12, got.?.args[1].pos.end);
        try testing.expectEqual(30, got.?.args[2].coordinates[0].number.value);
        try testing.expectEqual(31, got.?.args[2].coordinates[1].number.value);
        try testing.expectEqual(14, got.?.args[2].pos.start);
        try testing.expectEqual(18, got.?.args[2].pos.end);
        try testing.expectEqual(19, parser.pos);
    }

    {
        // Bad, invalid command
        //
        // Note that we assert this on reading the production, but it should
        // never come up in real-world use.
        var parser = init(
            testing.allocator,
            "test",
            1,
            "x 10,11",
        );
        defer parser.deinit();

        try testing.expectEqual(null, SmoothQuadraticBezierCurveTo.parse(&parser));
        try testing.expectEqual(.T_or_t, parser.err.?.expected);
        try testing.expectEqual(0, parser.err.?.pos.start);
        try testing.expectEqual(0, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:1: expected T_or_t, found 'x'\n");
    }

    {
        // Bad, incomplete arg
        var parser = init(
            testing.allocator,
            "test",
            1,
            "T 25,",
        );
        defer parser.deinit();

        try testing.expectEqual(null, SmoothQuadraticBezierCurveTo.parse(&parser));
        try testing.expectEqual(.coordinate_pair, parser.err.?.expected);
        try testing.expectEqual(2, parser.err.?.pos.start);
        try testing.expectEqual(4, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:3: expected coordinate_pair, found '25,'\n");
    }
}

test "EllipticalArc" {
    {
        // Good, single, absolute
        var parser = init(
            testing.allocator,
            "test",
            1,
            "A 25,26 -30 0,1 50,-25",
        );
        defer parser.deinit();

        const got = try EllipticalArc.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(false, got.?.relative);
        try testing.expectEqual(25, got.?.args[0].rx.value);
        try testing.expectEqual(26, got.?.args[0].ry.value);
        try testing.expectEqual(-30, got.?.args[0].x_axis_rotation.value);
        try testing.expectEqual(false, got.?.args[0].large_arc_flag.value);
        try testing.expectEqual(true, got.?.args[0].sweep_flag.value);
        try testing.expectEqual(50, got.?.args[0].point.coordinates[0].number.value);
        try testing.expectEqual(-25, got.?.args[0].point.coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(21, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(21, got.?.pos.end);
        try testing.expectEqual(22, parser.pos);
    }

    {
        // Good, single, relative
        var parser = init(
            testing.allocator,
            "test",
            1,
            "a 25,26 -30 0,1 50,-25 Z",
        );
        defer parser.deinit();

        const got = try EllipticalArc.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(true, got.?.relative);
        try testing.expectEqual(25, got.?.args[0].rx.value);
        try testing.expectEqual(26, got.?.args[0].ry.value);
        try testing.expectEqual(-30, got.?.args[0].x_axis_rotation.value);
        try testing.expectEqual(false, got.?.args[0].large_arc_flag.value);
        try testing.expectEqual(true, got.?.args[0].sweep_flag.value);
        try testing.expectEqual(50, got.?.args[0].point.coordinates[0].number.value);
        try testing.expectEqual(-25, got.?.args[0].point.coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(21, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(21, got.?.pos.end);
        try testing.expectEqual(22, parser.pos);
    }

    {
        // Good, multiple
        var parser = init(
            testing.allocator,
            "test",
            1,
            \\A 25,26 -30 0,1 50,-25
            \\26,51 -29 1,0 49,-26
            \\27,52 -28 0,1 48,-27 Z
            ,
        );
        defer parser.deinit();

        const got = try EllipticalArc.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(false, got.?.relative);
        try testing.expectEqual(25, got.?.args[0].rx.value);
        try testing.expectEqual(26, got.?.args[0].ry.value);
        try testing.expectEqual(-30, got.?.args[0].x_axis_rotation.value);
        try testing.expectEqual(false, got.?.args[0].large_arc_flag.value);
        try testing.expectEqual(true, got.?.args[0].sweep_flag.value);
        try testing.expectEqual(50, got.?.args[0].point.coordinates[0].number.value);
        try testing.expectEqual(-25, got.?.args[0].point.coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(21, got.?.args[0].pos.end);
        try testing.expectEqual(26, got.?.args[1].rx.value);
        try testing.expectEqual(51, got.?.args[1].ry.value);
        try testing.expectEqual(-29, got.?.args[1].x_axis_rotation.value);
        try testing.expectEqual(true, got.?.args[1].large_arc_flag.value);
        try testing.expectEqual(false, got.?.args[1].sweep_flag.value);
        try testing.expectEqual(49, got.?.args[1].point.coordinates[0].number.value);
        try testing.expectEqual(-26, got.?.args[1].point.coordinates[1].number.value);
        try testing.expectEqual(23, got.?.args[1].pos.start);
        try testing.expectEqual(42, got.?.args[1].pos.end);
        try testing.expectEqual(27, got.?.args[2].rx.value);
        try testing.expectEqual(52, got.?.args[2].ry.value);
        try testing.expectEqual(-28, got.?.args[2].x_axis_rotation.value);
        try testing.expectEqual(false, got.?.args[2].large_arc_flag.value);
        try testing.expectEqual(true, got.?.args[2].sweep_flag.value);
        try testing.expectEqual(48, got.?.args[2].point.coordinates[0].number.value);
        try testing.expectEqual(-27, got.?.args[2].point.coordinates[1].number.value);
        try testing.expectEqual(44, got.?.args[2].pos.start);
        try testing.expectEqual(63, got.?.args[2].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(63, got.?.pos.end);
        try testing.expectEqual(64, parser.pos);
    }

    {
        // Bad, invalid command
        //
        // Note that we assert this on reading the production, but it should
        // never come up in real-world use.
        var parser = init(
            testing.allocator,
            "test",
            1,
            "x 25,26 -30 0,1 50,-25",
        );
        defer parser.deinit();

        try testing.expectEqual(null, EllipticalArc.parse(&parser));
        try testing.expectEqual(.A_or_a, parser.err.?.expected);
        try testing.expectEqual(0, parser.err.?.pos.start);
        try testing.expectEqual(0, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:1: expected A_or_a, found 'x'\n");
    }

    {
        // Bad, incomplete arg
        var parser = init(
            testing.allocator,
            "test",
            1,
            "A 25,26 -30 Z",
        );
        defer parser.deinit();

        try testing.expectEqual(null, EllipticalArc.parse(&parser));
        try testing.expectEqual(.flag, parser.err.?.expected);
        try testing.expectEqual(12, parser.err.?.pos.start);
        try testing.expectEqual(12, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:13: expected flag, found 'Z'\n");
    }
}

test "EllipticalArcArgument" {
    {
        // Basic
        var parser = init(
            testing.allocator,
            "test",
            1,
            "25,26 -30 0,1 50,-25",
        );
        defer parser.deinit();

        const got = EllipticalArcArgument.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(25, got.?.rx.value);
        try testing.expectEqual(26, got.?.ry.value);
        try testing.expectEqual(-30, got.?.x_axis_rotation.value);
        try testing.expectEqual(false, got.?.large_arc_flag.value);
        try testing.expectEqual(true, got.?.sweep_flag.value);
        try testing.expectEqual(50, got.?.point.coordinates[0].number.value);
        try testing.expectEqual(-25, got.?.point.coordinates[1].number.value);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(19, got.?.pos.end);
        try testing.expectEqual(20, parser.pos);
    }

    {
        // Bad, negative rx
        var parser = init(
            testing.allocator,
            "test",
            1,
            "-25,26 -30 0,1 50,-25",
        );
        defer parser.deinit();

        try testing.expectEqual(null, EllipticalArcArgument.parse(&parser));
        try testing.expectEqual(.nonnegative_number, parser.err.?.expected);
        try testing.expectEqual(0, parser.err.?.pos.start);
        try testing.expectEqual(2, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:1: expected nonnegative_number, found '-25'\n");
    }

    {
        // Bad, negative ry
        var parser = init(
            testing.allocator,
            "test",
            1,
            "25,-26 -30 0,1 50,-25",
        );
        defer parser.deinit();

        try testing.expectEqual(null, EllipticalArcArgument.parse(&parser));
        try testing.expectEqual(.nonnegative_number, parser.err.?.expected);
        try testing.expectEqual(3, parser.err.?.pos.start);
        try testing.expectEqual(5, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:4: expected nonnegative_number, found '-26'\n");
    }

    {
        // Bad, non-number rotation
        var parser = init(
            testing.allocator,
            "test",
            1,
            "25,26 aa 0,1 50,-25",
        );
        defer parser.deinit();

        try testing.expectEqual(null, EllipticalArcArgument.parse(&parser));
        try testing.expectEqual(.number, parser.err.?.expected);
        try testing.expectEqual(6, parser.err.?.pos.start);
        try testing.expectEqual(6, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:7: expected number, found 'a'\n");
    }

    {
        // Bad, non-flag large-arc-flag
        var parser = init(
            testing.allocator,
            "test",
            1,
            "25,26 -30 2,1 50,-25",
        );
        defer parser.deinit();

        try testing.expectEqual(null, EllipticalArcArgument.parse(&parser));
        try testing.expectEqual(.flag, parser.err.?.expected);
        try testing.expectEqual(10, parser.err.?.pos.start);
        try testing.expectEqual(10, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:11: expected flag, found '2'\n");
    }

    {
        // Bad, non-flag sweep-flag
        var parser = init(
            testing.allocator,
            "test",
            1,
            "25,26 -30 0,2 50,-25",
        );
        defer parser.deinit();

        try testing.expectEqual(null, EllipticalArcArgument.parse(&parser));
        try testing.expectEqual(.flag, parser.err.?.expected);
        try testing.expectEqual(12, parser.err.?.pos.start);
        try testing.expectEqual(12, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:13: expected flag, found '2'\n");
    }

    {
        // Bad, non-number x
        var parser = init(
            testing.allocator,
            "test",
            1,
            "25,26 -30 0,1 a,-25",
        );
        defer parser.deinit();

        try testing.expectEqual(null, EllipticalArcArgument.parse(&parser));
        try testing.expectEqual(.coordinate_pair, parser.err.?.expected);
        try testing.expectEqual(14, parser.err.?.pos.start);
        try testing.expectEqual(14, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:15: expected coordinate_pair, found 'a'\n");
    }

    {
        // Bad, non-number y
        var parser = init(
            testing.allocator,
            "test",
            1,
            "25,26 -30 0,1 50,a",
        );
        defer parser.deinit();

        try testing.expectEqual(null, EllipticalArcArgument.parse(&parser));
        try testing.expectEqual(.coordinate_pair, parser.err.?.expected);
        try testing.expectEqual(14, parser.err.?.pos.start);
        try testing.expectEqual(17, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:15: expected coordinate_pair, found '50,a'\n");
    }
}

test "CoordinatePair" {
    {
        // Basic
        var parser = init(
            testing.allocator,
            "test",
            1,
            "123 456.789 123,456.789 123-456",
        );
        defer parser.deinit();

        var got = CoordinatePair.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(123, got.?.coordinates[0].number.value);
        try testing.expectEqual(456.789, got.?.coordinates[1].number.value);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(10, got.?.pos.end);
        try testing.expectEqual(11, parser.pos);

        parser.pos += 1;
        got = CoordinatePair.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(123, got.?.coordinates[0].number.value);
        try testing.expectEqual(456.789, got.?.coordinates[1].number.value);
        try testing.expectEqual(12, got.?.pos.start);
        try testing.expectEqual(22, got.?.pos.end);
        try testing.expectEqual(23, parser.pos);

        parser.pos += 1;
        got = CoordinatePair.parse(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(123, got.?.coordinates[0].number.value);
        try testing.expectEqual(-456, got.?.coordinates[1].number.value);
        try testing.expectEqual(24, got.?.pos.start);
        try testing.expectEqual(30, got.?.pos.end);
        try testing.expectEqual(31, parser.pos);

        try testing.expectEqual(null, CoordinatePair.parse(&parser));
        try testing.expectEqual(.coordinate_pair, parser.err.?.expected);
        try testing.expectEqual(31, parser.err.?.pos.start);
        try testing.expectEqual(31, parser.err.?.pos.end);
        try testing.expectEqual(31, parser.pos);
        try testError(&parser, "at test:1:31: expected coordinate_pair, found end of path data\n");
    }

    {
        // Bad, second arg
        var parser = init(
            testing.allocator,
            "test",
            1,
            "123,a",
        );
        defer parser.deinit();

        try testing.expectEqual(null, CoordinatePair.parse(&parser));
        try testing.expectEqual(.coordinate_pair, parser.err.?.expected);
        try testing.expectEqual(0, parser.err.?.pos.start);
        try testing.expectEqual(4, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:1: expected coordinate_pair, found '123,a'\n");
    }

    {
        // Bad, no second arg, end of path data
        var parser = init(
            testing.allocator,
            "test",
            1,
            "123,",
        );
        defer parser.deinit();

        try testing.expectEqual(null, CoordinatePair.parse(&parser));
        try testing.expectEqual(.coordinate_pair, parser.err.?.expected);
        try testing.expectEqual(0, parser.err.?.pos.start);
        try testing.expectEqual(3, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at test:1:1: expected coordinate_pair, found '123,'\n");
    }
}

test "Coordinate" {
    {
        // Basic
        var parser = init(
            testing.allocator,
            "test",
            1,
            "123 456.789",
        );
        defer parser.deinit();

        var got = Coordinate.parse(&parser);
        try testing.expectEqual(123, got.?.number.value);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(2, got.?.pos.end);
        try testing.expectEqual(3, parser.pos);

        parser.pos += 1;
        got = Coordinate.parse(&parser);
        try testing.expectEqual(456.789, got.?.number.value);
        try testing.expectEqual(4, got.?.pos.start);
        try testing.expectEqual(10, got.?.pos.end);
        try testing.expectEqual(11, parser.pos);
        try testing.expectEqual(null, Coordinate.parse(&parser));
    }
}

test "Flag" {
    {
        // Basic
        var parser = init(
            testing.allocator,
            "test",
            1,
            "0 1 2",
        );
        defer parser.deinit();

        var got = Flag.parse(&parser);
        try testing.expectEqual(false, got.?.value);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(0, got.?.pos.end);
        try testing.expectEqual(1, parser.pos);

        parser.pos += 1;
        got = Flag.parse(&parser);
        try testing.expectEqual(true, got.?.value);
        try testing.expectEqual(2, got.?.pos.start);
        try testing.expectEqual(2, got.?.pos.end);
        try testing.expectEqual(3, parser.pos);

        parser.pos += 1;
        try testing.expectEqual(null, Flag.parse(&parser));
    }
}

test "Number" {
    {
        // Basic
        var parser = init(
            testing.allocator,
            "test",
            1,
            "1 2 0 123 45a6 789 -123 123-123 123.456 +123+123",
        );
        defer parser.deinit();

        var got = Number.parse(&parser);
        try testing.expectEqual(1, got.?.value);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(0, got.?.pos.end);
        try testing.expectEqual(1, parser.pos);

        parser.pos += 1;
        got = Number.parse(&parser);
        try testing.expectEqual(2, got.?.value);
        try testing.expectEqual(2, got.?.pos.start);
        try testing.expectEqual(2, got.?.pos.end);
        try testing.expectEqual(3, parser.pos);

        parser.pos += 1;
        got = Number.parse(&parser);
        try testing.expectEqual(0, got.?.value);
        try testing.expectEqual(4, got.?.pos.start);
        try testing.expectEqual(4, got.?.pos.end);
        try testing.expectEqual(5, parser.pos);

        parser.pos += 1;
        got = Number.parse(&parser);
        try testing.expectEqual(123, got.?.value);
        try testing.expectEqual(6, got.?.pos.start);
        try testing.expectEqual(8, got.?.pos.end);
        try testing.expectEqual(9, parser.pos);

        parser.pos += 1;
        got = Number.parse(&parser);
        try testing.expectEqual(45, got.?.value);
        try testing.expectEqual(10, got.?.pos.start);
        try testing.expectEqual(11, got.?.pos.end);
        try testing.expectEqual(12, parser.pos);
        try testing.expectEqual(null, Number.parse(&parser));

        parser.pos += 1;
        got = Number.parse(&parser);
        try testing.expectEqual(6, got.?.value);
        try testing.expectEqual(13, got.?.pos.start);
        try testing.expectEqual(13, got.?.pos.end);
        try testing.expectEqual(14, parser.pos);

        parser.pos += 1;
        got = Number.parse(&parser);
        try testing.expectEqual(789, got.?.value);
        try testing.expectEqual(15, got.?.pos.start);
        try testing.expectEqual(17, got.?.pos.end);
        try testing.expectEqual(18, parser.pos);

        parser.pos += 1;
        got = Number.parse(&parser);
        try testing.expectEqual(-123, got.?.value);
        try testing.expectEqual(19, got.?.pos.start);
        try testing.expectEqual(22, got.?.pos.end);
        try testing.expectEqual(23, parser.pos);

        parser.pos += 1;
        got = Number.parse(&parser);
        try testing.expectEqual(123, got.?.value);
        try testing.expectEqual(24, got.?.pos.start);
        try testing.expectEqual(26, got.?.pos.end);
        try testing.expectEqual(27, parser.pos);

        got = Number.parse(&parser);
        try testing.expectEqual(-123, got.?.value);
        try testing.expectEqual(27, got.?.pos.start);
        try testing.expectEqual(30, got.?.pos.end);
        try testing.expectEqual(31, parser.pos);

        parser.pos += 1;
        got = Number.parse(&parser);
        try testing.expectEqual(123.456, got.?.value);
        try testing.expectEqual(32, got.?.pos.start);
        try testing.expectEqual(38, got.?.pos.end);
        try testing.expectEqual(39, parser.pos);

        parser.pos += 1;
        got = Number.parse(&parser);
        try testing.expectEqual(123, got.?.value);
        try testing.expectEqual(40, got.?.pos.start);
        try testing.expectEqual(43, got.?.pos.end);
        try testing.expectEqual(44, parser.pos);

        got = Number.parse(&parser);
        try testing.expectEqual(123, got.?.value);
        try testing.expectEqual(44, got.?.pos.start);
        try testing.expectEqual(47, got.?.pos.end);
        try testing.expectEqual(48, parser.pos);

        try testing.expectEqual(null, Number.parse(&parser));
    }

    {
        // Exponents
        var parser = init(
            testing.allocator,
            "test",
            1,
            "10e1 10e+1 10e-1 10e10 10ee 10e.1 -.1e1 0.01e+2",
        );
        defer parser.deinit();

        var got = Number.parse(&parser);
        try testing.expectEqual(100, got.?.value);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(3, got.?.pos.end);
        try testing.expectEqual(4, parser.pos);

        parser.pos += 1;
        got = Number.parse(&parser);
        try testing.expectEqual(100, got.?.value);
        try testing.expectEqual(5, got.?.pos.start);
        try testing.expectEqual(9, got.?.pos.end);
        try testing.expectEqual(10, parser.pos);

        parser.pos += 1;
        got = Number.parse(&parser);
        try testing.expectEqual(1, got.?.value);
        try testing.expectEqual(11, got.?.pos.start);
        try testing.expectEqual(15, got.?.pos.end);
        try testing.expectEqual(16, parser.pos);

        parser.pos += 1;
        got = Number.parse(&parser);
        try testing.expectEqual(100000000000, got.?.value);
        try testing.expectEqual(17, got.?.pos.start);
        try testing.expectEqual(21, got.?.pos.end);
        try testing.expectEqual(22, parser.pos);

        parser.pos += 1;
        got = Number.parse(&parser);
        try testing.expectEqual(10, got.?.value);
        try testing.expectEqual(23, got.?.pos.start);
        try testing.expectEqual(24, got.?.pos.end);
        try testing.expectEqual(25, parser.pos);
        try testing.expectEqual(null, Number.parse(&parser));

        parser.pos += 3;
        got = Number.parse(&parser);
        try testing.expectEqual(10, got.?.value);
        try testing.expectEqual(28, got.?.pos.start);
        try testing.expectEqual(29, got.?.pos.end);
        try testing.expectEqual(30, parser.pos);
        try testing.expectEqual(null, Number.parse(&parser));

        parser.pos += 1;
        got = Number.parse(&parser);
        try testing.expectEqual(0.1, got.?.value);
        try testing.expectEqual(31, got.?.pos.start);
        try testing.expectEqual(32, got.?.pos.end);
        try testing.expectEqual(33, parser.pos);

        parser.pos += 1;
        got = Number.parse(&parser);
        try testing.expectEqual(-1, got.?.value);
        try testing.expectEqual(34, got.?.pos.start);
        try testing.expectEqual(38, got.?.pos.end);
        try testing.expectEqual(39, parser.pos);

        parser.pos += 1;
        got = Number.parse(&parser);
        try testing.expectEqual(1, got.?.value);
        try testing.expectEqual(40, got.?.pos.start);
        try testing.expectEqual(46, got.?.pos.end);
        try testing.expectEqual(47, parser.pos);
    }
}

test "consumeWhitespace" {
    {
        var parser = init(
            testing.allocator,
            "test",
            1,
            "   a  ",
        );
        defer parser.deinit();

        parser.consumeWhitespace();
        try testing.expectEqual(3, parser.pos);
        parser.consumeWhitespace();
        try testing.expectEqual(3, parser.pos);
        parser.pos += 1;
        parser.consumeWhitespace();
        try testing.expectEqual(6, parser.pos);
        parser.consumeWhitespace();
        try testing.expectEqual(6, parser.pos);
    }
}

test "consumeCommaWhitespace" {
    {
        var parser = init(
            testing.allocator,
            "test",
            1,
            "   ,  a  a  ,,",
        );
        defer parser.deinit();

        parser.consumeCommaWhitespace();
        try testing.expectEqual(6, parser.pos);
        parser.consumeCommaWhitespace();
        try testing.expectEqual(6, parser.pos);

        parser.pos += 1;
        parser.consumeCommaWhitespace();
        try testing.expectEqual(9, parser.pos);
        parser.consumeCommaWhitespace();
        try testing.expectEqual(9, parser.pos);

        parser.pos += 1;
        parser.consumeCommaWhitespace();
        try testing.expectEqual(13, parser.pos);
        parser.consumeCommaWhitespace();
        try testing.expectEqual(14, parser.pos);
    }
}

/// For testing only.
fn testError(p: *Path, expected: [:0]const u8) !void {
    var buf = [_:0]u8{0} ** 256;
    var stream = io.fixedBufferStream(&buf);
    const writer = stream.writer();
    try p.fmtErr(writer);
    try testing.expectEqualSentinel(
        u8,
        0,
        expected,
        buf[0..expected.len :0],
    );
}

test "fmtErr" {
    {
        // Basic
        var parser = init(
            testing.allocator,
            "test",
            1,
            "abc def ghi",
        );
        defer parser.deinit();
        parser.err = .{
            .expected = .coordinate_pair,
            .pos = .{
                .start = 8,
                .end = 10,
            },
        };

        try testError(&parser, "at test:1:9: expected coordinate_pair, found 'ghi'\n");
    }
}
