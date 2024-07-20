// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

//! The SVG package contains parsers for various SVG attribute representations.
//! It does not include XML parsing; for that, use a separate XML parser.
//!
//! ## Parsing
//!
//! All useful primitives will have a parse function that you can call to
//! perform the parsing. An example for path is below:
//!
//! ```
//! const Path = @import("svg").Path;
//! var path = try Path.parse(alloc, data);
//! defer path.deinit();
//! for (path.nodes) |n| {
//!   ...
//! }
//! ```
//!
//! ## Errors
//!
//!
//! Only errors in allocation are reported as errors. All other errors are
//! non-fatal and are reported in the `err` attribute instead. This allows for
//! partial SVG processing as per the spec.
//!
//! ```
//! const io = @import("std").io;
//! const log = @import("std").log;
//! const Path = @import("svg").Path;
//! var path = try Path.parse(alloc, data);
//! defer path.deinit();
//! if (path.err) |err| {
//!     const errWriter = io.getStdErr();
//!     buf.format(errWriter, "error processing SVG: ");
//!     try path.parser.fmtErr(errWriter);
//! }
//!
//! for (path.nodes) |n| {
//!   ...
//! }
//! ```

const std = @import("std");
const debug = @import("std").debug;
const fmt = @import("std").fmt;
const heap = @import("std").heap;
const io = @import("std").io;
const log = @import("std").log;
const math = @import("std").math;
const mem = @import("std").mem;
const testing = @import("std").testing;

/// Path is an SVG path node representation.
///
/// See the root package description for an example for its usage.
pub const Path = struct {
    parser: Parser,

    /// The nodes that belong to this path. Populated by `parse`.
    nodes: []Node = &[_]Node{},

    // All parsed items are stored in the arena, e.g., any `ArrayList`s that we use
    // to build multi-arg nodes use this arena as a backing store. `deinit` clears
    // the arena.
    arena: heap.ArenaAllocator,

    /// Returns a parsed path node set. Call `deinit` to de-allocate path data.
    pub fn parse(alloc: mem.Allocator, data: []const u8) !Path {
        var result = init(alloc, data);
        errdefer result.deinit();
        try result._parse();
        return result;
    }

    /// Releases stored node data. The node set is invalid to use after this.
    pub fn deinit(self: *Path) void {
        self.arena.deinit();
    }

    fn init(alloc: mem.Allocator, data: []const u8) Path {
        return .{
            .arena = heap.ArenaAllocator.init(alloc),
            .parser = .{ .data = data },
        };
    }

    fn _parse(self: *Path) !void {
        var result = std.ArrayList(Node).init(self.arena.allocator());
        errdefer result.deinit();

        self.parser.consumeWhitespace();
        if (try MoveTo.parse(self)) |n|
            try result.append(.{ .move_to = n })
        else
            return;

        self.parser.consumeWhitespace();

        while (self.parser.pos < self.parser.data.len) {
            switch (self.parser.data[self.parser.pos]) {
                'M', 'm' => {
                    if (try MoveTo.parse(self)) |n|
                        try result.append(.{ .move_to = n })
                    else
                        break;
                },
                'Z', 'z' => {
                    if (try ClosePath.parse(self)) |n|
                        try result.append(.{ .close_path = n })
                    else
                        break;
                },
                'L', 'l' => {
                    if (try LineTo.parse(self)) |n|
                        try result.append(.{ .line_to = n })
                    else
                        break;
                },
                'H', 'h' => {
                    if (try HorizontalLineTo.parse(self)) |n|
                        try result.append(.{ .horizontal_line_to = n })
                    else
                        break;
                },
                'V', 'v' => {
                    if (try VerticalLineTo.parse(self)) |n|
                        try result.append(.{ .vertical_line_to = n })
                    else
                        break;
                },
                'C', 'c' => {
                    if (try CurveTo.parse(self)) |n|
                        try result.append(.{ .curve_to = n })
                    else
                        break;
                },
                'S', 's' => {
                    if (try SmoothCurveTo.parse(self)) |n|
                        try result.append(.{ .smooth_curve_to = n })
                    else
                        break;
                },
                'Q', 'q' => {
                    if (try QuadraticBezierCurveTo.parse(self)) |n|
                        try result.append(.{ .quadratic_bezier_curve_to = n })
                    else
                        break;
                },
                'T', 't' => {
                    if (try SmoothQuadraticBezierCurveTo.parse(self)) |n|
                        try result.append(.{ .smooth_quadratic_bezier_curve_to = n })
                    else
                        break;
                },
                'A', 'a' => {
                    if (try EllipticalArc.parse(self)) |n|
                        try result.append(.{ .elliptical_arc = n })
                    else
                        break;
                },
                else => {
                    self.parser.setErr(.drawto_command, self.parser.pos, self.parser.pos, self.parser.pos);
                    break;
                },
            }
            self.parser.consumeWhitespace();
        }

        self.nodes = result.items;
    }

    pub const NodeType = enum {
        move_to,
        close_path,
        line_to,
        horizontal_line_to,
        vertical_line_to,
        curve_to,
        smooth_curve_to,
        quadratic_bezier_curve_to,
        smooth_quadratic_bezier_curve_to,
        elliptical_arc,
    };

    /// The union of all valid path nodes.
    pub const Node = union(NodeType) {
        move_to: MoveTo,
        close_path: ClosePath,
        line_to: LineTo,
        horizontal_line_to: HorizontalLineTo,
        vertical_line_to: VerticalLineTo,
        curve_to: CurveTo,
        smooth_curve_to: SmoothCurveTo,
        quadratic_bezier_curve_to: QuadraticBezierCurveTo,
        smooth_quadratic_bezier_curve_to: SmoothQuadraticBezierCurveTo,
        elliptical_arc: EllipticalArc,
    };

    /// Represents a moveto command ('M' or 'm').
    pub const MoveTo = struct {
        relative: bool,
        args: []CoordinatePair,
        pos: Parser.Pos,

        fn parse(self: *Path) !?MoveTo {
            const reset = self.parser.pos;
            var start = self.parser.pos;
            var relative: bool = undefined;
            var pos: Parser.Pos = undefined;
            var args = std.ArrayList(CoordinatePair).init(self.arena.allocator());
            errdefer args.deinit();

            switch (self.parser.data[self.parser.pos]) {
                'M' => relative = false,
                'm' => relative = true,
                else => {
                    self.parser.setErr(.M_or_m, start, self.parser.pos, reset);
                    args.deinit();
                    return null;
                },
            }

            pos.start = self.parser.pos;
            pos.end = self.parser.pos;
            self.parser.pos += 1;
            self.parser.consumeWhitespace();

            start = self.parser.pos;
            if (CoordinatePair.parse(&self.parser)) |a| {
                try args.append(a);
                pos.end = a.pos.end;
            } else {
                debug.assert(self.parser.err != null);
                // Error has already been set, but we need to reset our position
                self.parser.pos = reset;
                args.deinit();
                return null;
            }

            start = self.parser.pos;
            self.consumeCommaWhitespace();
            while (CoordinatePair.parse(&self.parser)) |a| {
                try args.append(a);
                pos.end = a.pos.end;
                start = self.parser.pos;
                self.consumeCommaWhitespace();
            }

            // Rewind to right after the end of last good consumed sequence, and
            // clear any errors
            self.parser.pos = start;
            self.parser.err = null;
            return .{
                .relative = relative,
                .args = args.items,
                .pos = pos,
            };
        }
    };

    /// Represents a closepath command ('Z' or 'z').
    pub const ClosePath = struct {
        pos: Parser.Pos,

        fn parse(self: *Path) !?ClosePath {
            switch (self.parser.data[self.parser.pos]) {
                'Z', 'z' => {},
                else => {
                    self.parser.setErr(.Z_or_z, self.parser.pos, self.parser.pos, self.parser.pos);
                    return null;
                },
            }

            const pos: Parser.Pos = .{
                .start = self.parser.pos,
                .end = self.parser.pos,
            };
            self.parser.pos += 1;
            return .{
                .pos = pos,
            };
        }
    };

    /// Represents a lineto command ('L' or 'l').
    pub const LineTo = struct {
        relative: bool,
        args: []CoordinatePair,
        pos: Parser.Pos,

        fn parse(self: *Path) !?LineTo {
            const reset = self.parser.pos;
            var start = self.parser.pos;
            var relative: bool = undefined;
            var pos: Parser.Pos = undefined;
            var args = std.ArrayList(CoordinatePair).init(self.arena.allocator());
            errdefer args.deinit();

            switch (self.parser.data[self.parser.pos]) {
                'L' => relative = false,
                'l' => relative = true,
                else => {
                    self.parser.setErr(.L_or_l, start, self.parser.pos, reset);
                    args.deinit();
                    return null;
                },
            }

            pos.start = self.parser.pos;
            pos.end = self.parser.pos;
            self.parser.pos += 1;
            self.parser.consumeWhitespace();

            start = self.parser.pos;
            if (CoordinatePair.parse(&self.parser)) |a| {
                try args.append(a);
                pos.end = a.pos.end;
            } else {
                debug.assert(self.parser.err != null);
                // Error has already been set, but we need to reset our position
                self.parser.pos = reset;
                args.deinit();
                return null;
            }

            start = self.parser.pos;
            self.consumeCommaWhitespace();
            while (CoordinatePair.parse(&self.parser)) |a| {
                try args.append(a);
                pos.end = a.pos.end;
                start = self.parser.pos;
                self.consumeCommaWhitespace();
            }

            // Rewind to right after the end of last good consumed sequence, and
            // clear any errors
            self.parser.pos = start;
            self.parser.err = null;
            return .{
                .relative = relative,
                .args = args.items,
                .pos = pos,
            };
        }
    };

    /// Represents a horizontal lineto command ('H' or 'h').
    pub const HorizontalLineTo = struct {
        relative: bool,
        args: []Number,
        pos: Parser.Pos,

        fn parse(self: *Path) !?HorizontalLineTo {
            const reset = self.parser.pos;
            var start = self.parser.pos;
            var relative: bool = undefined;
            var pos: Parser.Pos = undefined;
            var args = std.ArrayList(Number).init(self.arena.allocator());
            errdefer args.deinit();

            switch (self.parser.data[self.parser.pos]) {
                'H' => relative = false,
                'h' => relative = true,
                else => {
                    self.parser.setErr(.H_or_h, start, self.parser.pos, reset);
                    args.deinit();
                    return null;
                },
            }

            pos.start = self.parser.pos;
            pos.end = self.parser.pos;
            self.parser.pos += 1;
            self.parser.consumeWhitespace();

            start = self.parser.pos;
            if (Number.parse(&self.parser)) |a| {
                try args.append(a);
                pos.end = a.pos.end;
            } else {
                self.parser.setErr(.number, start, self.parser.pos, reset);
                args.deinit();
                return null;
            }

            start = self.parser.pos;
            self.consumeCommaWhitespace();
            while (Number.parse(&self.parser)) |a| {
                try args.append(a);
                pos.end = a.pos.end;
                start = self.parser.pos;
                self.consumeCommaWhitespace();
            }

            // Rewind to right after the end of last good consumed sequence, and
            // clear any errors
            self.parser.pos = start;
            self.parser.err = null;
            return .{
                .relative = relative,
                .args = args.items,
                .pos = pos,
            };
        }
    };

    /// Represents a vertical lineto command ('V' or 'v').
    pub const VerticalLineTo = struct {
        relative: bool,
        args: []Number,
        pos: Parser.Pos,

        fn parse(self: *Path) !?VerticalLineTo {
            const reset = self.parser.pos;
            var start = self.parser.pos;
            var relative: bool = undefined;
            var pos: Parser.Pos = undefined;
            var args = std.ArrayList(Number).init(self.arena.allocator());
            errdefer args.deinit();

            switch (self.parser.data[self.parser.pos]) {
                'V' => relative = false,
                'v' => relative = true,
                else => {
                    self.parser.setErr(.V_or_v, start, self.parser.pos, reset);
                    args.deinit();
                    return null;
                },
            }

            pos.start = self.parser.pos;
            pos.end = self.parser.pos;
            self.parser.pos += 1;
            self.parser.consumeWhitespace();

            start = self.parser.pos;
            if (Number.parse(&self.parser)) |a| {
                try args.append(a);
                pos.end = a.pos.end;
            } else {
                self.parser.setErr(.number, start, self.parser.pos, reset);
                args.deinit();
                return null;
            }

            start = self.parser.pos;
            self.consumeCommaWhitespace();
            while (Number.parse(&self.parser)) |a| {
                try args.append(a);
                pos.end = a.pos.end;
                start = self.parser.pos;
                self.consumeCommaWhitespace();
            }

            // Rewind to right after the end of last good consumed sequence, and
            // clear any errors
            self.parser.pos = start;
            self.parser.err = null;
            return .{
                .relative = relative,
                .args = args.items,
                .pos = pos,
            };
        }
    };

    /// Represents a curveto command ('C' or 'c').
    pub const CurveTo = struct {
        relative: bool,
        args: []CurveToArgument,
        pos: Parser.Pos,

        fn parse(self: *Path) !?CurveTo {
            const reset = self.parser.pos;
            var start = self.parser.pos;
            var relative: bool = undefined;
            var pos: Parser.Pos = undefined;
            var args = std.ArrayList(CurveToArgument).init(self.arena.allocator());
            errdefer args.deinit();

            switch (self.parser.data[self.parser.pos]) {
                'C' => relative = false,
                'c' => relative = true,
                else => {
                    self.parser.setErr(.C_or_c, start, self.parser.pos, reset);
                    args.deinit();
                    return null;
                },
            }

            pos.start = self.parser.pos;
            pos.end = self.parser.pos;
            self.parser.pos += 1;
            self.parser.consumeWhitespace();

            start = self.parser.pos;
            if (CurveToArgument.parse(self)) |a| {
                try args.append(a);
                pos.end = a.pos.end;
            } else {
                debug.assert(self.parser.err != null);
                // Error has already been set, but we need to reset our position
                self.parser.pos = reset;
                args.deinit();
                return null;
            }

            start = self.parser.pos;
            self.consumeCommaWhitespace();
            while (CurveToArgument.parse(self)) |a| {
                try args.append(a);
                pos.end = a.pos.end;
                start = self.parser.pos;
                self.consumeCommaWhitespace();
            }

            // Rewind to right after the end of last good consumed sequence, and
            // clear any errors
            self.parser.pos = start;
            self.parser.err = null;
            return .{
                .relative = relative,
                .args = args.items,
                .pos = pos,
            };
        }
    };

    /// Represents the 3-pair argument to a curveto command ('C' or 'c').
    pub const CurveToArgument = struct {
        p1: CoordinatePair,
        p2: CoordinatePair,
        end: CoordinatePair,
        pos: Parser.Pos,

        fn parse(self: *Path) ?CurveToArgument {
            const reset = self.parser.pos;
            var result: CurveToArgument = undefined;
            if (CoordinatePair.parse(&self.parser)) |p| {
                result.p1 = p;
                result.pos = p.pos;
            } else {
                debug.assert(self.parser.err != null);
                // Error has already been set, but we need to reset our position
                self.parser.pos = reset;
                return null;
            }

            self.consumeCommaWhitespace();

            if (CoordinatePair.parse(&self.parser)) |p| {
                result.p2 = p;
                result.pos.end = p.pos.end;
            } else {
                debug.assert(self.parser.err != null);
                // Error has already been set, but we need to reset our position
                self.parser.pos = reset;
                return null;
            }

            self.consumeCommaWhitespace();

            if (CoordinatePair.parse(&self.parser)) |p| {
                result.end = p;
                result.pos.end = p.pos.end;
            } else {
                debug.assert(self.parser.err != null);
                // Error has already been set, but we need to reset our position
                self.parser.pos = reset;
                return null;
            }

            return result;
        }
    };

    /// Represents a smooth curveto command ('S' or 's').
    pub const SmoothCurveTo = struct {
        relative: bool,
        args: []SmoothCurveToArgument,
        pos: Parser.Pos,

        fn parse(self: *Path) !?SmoothCurveTo {
            const reset = self.parser.pos;
            var start = self.parser.pos;
            var relative: bool = undefined;
            var pos: Parser.Pos = undefined;
            var args = std.ArrayList(SmoothCurveToArgument).init(self.arena.allocator());
            errdefer args.deinit();

            switch (self.parser.data[self.parser.pos]) {
                'S' => relative = false,
                's' => relative = true,
                else => {
                    self.parser.setErr(.S_or_s, start, self.parser.pos, reset);
                    args.deinit();
                    return null;
                },
            }

            pos.start = self.parser.pos;
            pos.end = self.parser.pos;
            self.parser.pos += 1;
            self.parser.consumeWhitespace();

            start = self.parser.pos;
            if (SmoothCurveToArgument.parse(self)) |a| {
                try args.append(a);
                pos.end = a.pos.end;
            } else {
                debug.assert(self.parser.err != null);
                // Error has already been set, but we need to reset our position
                self.parser.pos = reset;
                args.deinit();
                return null;
            }

            start = self.parser.pos;
            self.consumeCommaWhitespace();
            while (SmoothCurveToArgument.parse(self)) |a| {
                try args.append(a);
                pos.end = a.pos.end;
                start = self.parser.pos;
                self.consumeCommaWhitespace();
            }

            // Rewind to right after the end of last good consumed sequence, and
            // clear any errors
            self.parser.pos = start;
            self.parser.err = null;
            return .{
                .relative = relative,
                .args = args.items,
                .pos = pos,
            };
        }
    };

    /// Represents the 2-pair argument to a smooth curveto command ('S' or 's').
    pub const SmoothCurveToArgument = struct {
        p2: CoordinatePair,
        end: CoordinatePair,
        pos: Parser.Pos,

        fn parse(self: *Path) ?SmoothCurveToArgument {
            const reset = self.parser.pos;
            var result: SmoothCurveToArgument = undefined;
            if (CoordinatePair.parse(&self.parser)) |p| {
                result.p2 = p;
                result.pos = p.pos;
            } else {
                debug.assert(self.parser.err != null);
                // Error has already been set, but we need to reset our position
                self.parser.pos = reset;
                return null;
            }

            self.consumeCommaWhitespace();

            if (CoordinatePair.parse(&self.parser)) |p| {
                result.end = p;
                result.pos.end = p.pos.end;
            } else {
                debug.assert(self.parser.err != null);
                // Error has already been set, but we need to reset our position
                self.parser.pos = reset;
                return null;
            }

            return result;
        }
    };

    /// Represents a quadratic curveto command ('Q' or 'q').
    pub const QuadraticBezierCurveTo = struct {
        relative: bool,
        args: []QuadraticBezierCurveToArgument,
        pos: Parser.Pos,

        fn parse(self: *Path) !?QuadraticBezierCurveTo {
            const reset = self.parser.pos;
            var start = self.parser.pos;
            var relative: bool = undefined;
            var pos: Parser.Pos = undefined;
            var args = std.ArrayList(QuadraticBezierCurveToArgument).init(self.arena.allocator());
            errdefer args.deinit();

            switch (self.parser.data[self.parser.pos]) {
                'Q' => relative = false,
                'q' => relative = true,
                else => {
                    self.parser.setErr(.Q_or_q, start, self.parser.pos, reset);
                    args.deinit();
                    return null;
                },
            }

            pos.start = self.parser.pos;
            pos.end = self.parser.pos;
            self.parser.pos += 1;
            self.parser.consumeWhitespace();

            start = self.parser.pos;
            if (QuadraticBezierCurveToArgument.parse(self)) |a| {
                try args.append(a);
                pos.end = a.pos.end;
            } else {
                debug.assert(self.parser.err != null);
                // Error has already been set, but we need to reset our position
                self.parser.pos = reset;
                args.deinit();
                return null;
            }

            start = self.parser.pos;
            self.consumeCommaWhitespace();
            while (QuadraticBezierCurveToArgument.parse(self)) |a| {
                try args.append(a);
                pos.end = a.pos.end;
                start = self.parser.pos;
                self.consumeCommaWhitespace();
            }

            // Rewind to right after the end of last good consumed sequence, and
            // clear any errors
            self.parser.pos = start;
            self.parser.err = null;
            return .{
                .relative = relative,
                .args = args.items,
                .pos = pos,
            };
        }
    };

    /// Represents the 2-pair argument to a quadratic curveto command ('Q' or 'q').
    pub const QuadraticBezierCurveToArgument = struct {
        p1: CoordinatePair,
        end: CoordinatePair,
        pos: Parser.Pos,

        fn parse(self: *Path) ?QuadraticBezierCurveToArgument {
            const reset = self.parser.pos;
            var result: QuadraticBezierCurveToArgument = undefined;
            if (CoordinatePair.parse(&self.parser)) |p| {
                result.p1 = p;
                result.pos = p.pos;
            } else {
                debug.assert(self.parser.err != null);
                // Error has already been set, but we need to reset our position
                self.parser.pos = reset;
                return null;
            }

            self.consumeCommaWhitespace();

            if (CoordinatePair.parse(&self.parser)) |p| {
                result.end = p;
                result.pos.end = p.pos.end;
            } else {
                debug.assert(self.parser.err != null);
                // Error has already been set, but we need to reset our position
                self.parser.pos = reset;
                return null;
            }

            return result;
        }
    };

    /// Represents a smooth quadratic curveto command ('T' or 't').
    pub const SmoothQuadraticBezierCurveTo = struct {
        relative: bool,
        args: []CoordinatePair,
        pos: Parser.Pos,

        fn parse(self: *Path) !?SmoothQuadraticBezierCurveTo {
            const reset = self.parser.pos;
            var start = self.parser.pos;
            var relative: bool = undefined;
            var pos: Parser.Pos = undefined;
            var args = std.ArrayList(CoordinatePair).init(self.arena.allocator());
            errdefer args.deinit();

            switch (self.parser.data[self.parser.pos]) {
                'T' => relative = false,
                't' => relative = true,
                else => {
                    self.parser.setErr(.T_or_t, start, self.parser.pos, reset);
                    args.deinit();
                    return null;
                },
            }

            pos.start = self.parser.pos;
            pos.end = self.parser.pos;
            self.parser.pos += 1;
            self.parser.consumeWhitespace();

            start = self.parser.pos;
            if (CoordinatePair.parse(&self.parser)) |a| {
                try args.append(a);
                pos.end = a.pos.end;
            } else {
                debug.assert(self.parser.err != null);
                // Error has already been set, but we need to reset our position
                self.parser.pos = reset;
                args.deinit();
                return null;
            }

            start = self.parser.pos;
            self.consumeCommaWhitespace();
            while (CoordinatePair.parse(&self.parser)) |a| {
                try args.append(a);
                pos.end = a.pos.end;
                start = self.parser.pos;
                self.consumeCommaWhitespace();
            }

            // Rewind to right after the end of last good consumed sequence, and
            // clear any errors
            self.parser.pos = start;
            self.parser.err = null;
            return .{
                .relative = relative,
                .args = args.items,
                .pos = pos,
            };
        }
    };

    /// Represents an elliptical arc command ('A' or 'a').
    pub const EllipticalArc = struct {
        relative: bool,
        args: []EllipticalArcArgument,
        pos: Parser.Pos,

        fn parse(self: *Path) !?EllipticalArc {
            const reset = self.parser.pos;
            var start = self.parser.pos;
            var relative: bool = undefined;
            var pos: Parser.Pos = undefined;
            var args = std.ArrayList(EllipticalArcArgument).init(self.arena.allocator());
            errdefer args.deinit();

            switch (self.parser.data[self.parser.pos]) {
                'A' => relative = false,
                'a' => relative = true,
                else => {
                    self.parser.setErr(.A_or_a, start, self.parser.pos, reset);
                    args.deinit();
                    return null;
                },
            }

            pos.start = self.parser.pos;
            pos.end = self.parser.pos;
            self.parser.pos += 1;
            self.parser.consumeWhitespace();

            start = self.parser.pos;
            if (EllipticalArcArgument.parse(self)) |a| {
                try args.append(a);
                pos.end = a.pos.end;
            } else {
                debug.assert(self.parser.err != null);
                // Error has already been set, but we need to reset our position
                self.parser.pos = reset;
                args.deinit();
                return null;
            }

            start = self.parser.pos;
            self.consumeCommaWhitespace();
            while (EllipticalArcArgument.parse(self)) |a| {
                try args.append(a);
                pos.end = a.pos.end;
                start = self.parser.pos;
                self.consumeCommaWhitespace();
            }

            // Rewind to right after the end of last good consumed sequence, and
            // clear any errors
            self.parser.pos = start;
            self.parser.err = null;
            return .{
                .relative = relative,
                .args = args.items,
                .pos = pos,
            };
        }
    };

    /// Represents the set of parameters to an elliptical arc command ('A' or 'a').
    pub const EllipticalArcArgument = struct {
        rx: Number,
        ry: Number,
        x_axis_rotation: Number,
        large_arc_flag: Flag,
        sweep_flag: Flag,
        point: CoordinatePair,
        pos: Parser.Pos,

        fn parse(self: *Path) ?EllipticalArcArgument {
            const reset = self.parser.pos;
            var start = self.parser.pos;
            var result: EllipticalArcArgument = undefined;
            if (Number.parse(&self.parser)) |n| {
                if (n.value < 0) {
                    // Note: we rewind the end point here by 1 as we're asserting
                    // on a valid value, so our position is on the next character
                    // to be read.
                    self.parser.setErr(.nonnegative_number, start, self.parser.pos - 1, reset);
                    return null;
                }
                result.rx = n;
                result.pos = n.pos;
            } else {
                self.parser.setErr(.nonnegative_number, start, self.parser.pos, reset);
                return null;
            }

            self.consumeCommaWhitespace();

            start = self.parser.pos;
            if (Number.parse(&self.parser)) |n| {
                if (n.value < 0) {
                    self.parser.setErr(.nonnegative_number, start, self.parser.pos - 1, reset);
                    return null;
                }
                result.ry = n;
                result.pos.end = n.pos.end;
            } else {
                self.parser.setErr(.nonnegative_number, start, self.parser.pos, reset);
                return null;
            }

            self.consumeCommaWhitespace();

            start = self.parser.pos;
            if (Number.parse(&self.parser)) |n| {
                result.x_axis_rotation = n;
                result.pos.end = n.pos.end;
            } else {
                self.parser.setErr(.number, start, self.parser.pos, reset);
                return null;
            }

            self.consumeCommaWhitespace();

            start = self.parser.pos;
            if (Flag.parse(&self.parser)) |f| {
                result.large_arc_flag = f;
                result.pos.end = f.pos.end;
            } else {
                self.parser.setErr(.flag, start, self.parser.pos, reset);
                return null;
            }

            self.consumeCommaWhitespace();

            start = self.parser.pos;
            if (Flag.parse(&self.parser)) |f| {
                result.sweep_flag = f;
                result.pos.end = f.pos.end;
            } else {
                self.parser.setErr(.flag, start, self.parser.pos, reset);
                return null;
            }

            self.consumeCommaWhitespace();

            if (CoordinatePair.parse(&self.parser)) |p| {
                result.point = p;
                result.pos.end = p.pos.end;
            } else {
                debug.assert(self.parser.err != null);
                // Error has already been set, but we need to reset our position
                self.parser.pos = reset;
                return null;
            }

            return result;
        }
    };

    fn consumeCommaWhitespace(self: *Path) void {
        _ = self.parser.consumeCommaWhitespace();
    }
};

/// Represents a CSS2 compatible specification for a color in the sRGB color
/// space.
pub const Color = struct {
    parser: Parser,
    value: Value,

    const Value = struct {
        r: u8,
        g: u8,
        b: u8,
    };

    pub fn parse(data: []const u8) Color {
        var result: Color = .{
            .parser = .{ .data = data },
            .value = .{ .r = 0, .g = 0, .b = 0 },
        };

        if (result.parser.data.len > 0 and result.parser.data[0] == '#') {
            if (parseHex(&result.parser)) |parsed| {
                result.value = parsed;
            }
        } else if (result.parser.data.len >= 4 and mem.eql(u8, result.parser.data[0..4], "rgb(")) {
            if (parseIntPercent(&result.parser)) |parsed| {
                result.value = parsed;
            }
        } else if (parseName(result.parser.data)) |parsed| {
            result.parser.pos = result.parser.data.len;
            result.value = parsed;
        } else {
            result.parser.setErr(.color_keyword, 0, result.parser.data.len - 1, 0);
        }

        return result;
    }

    fn parseHex(self: *Parser) ?Value {
        if (self.data.len < 1 or self.data[0] != '#') {
            self.setErr(.hash, 0, 0, 0);
            return null;
        }

        const len: usize = l: {
            switch (self.data.len - 1) {
                3 => break :l 1,
                6 => break :l 2,
                else => {
                    self.setErr(.rgb_hex, 0, self.data.len - 1, 0);
                    return null;
                },
            }
        };

        var result: Value = undefined;
        self.pos = 1;
        if (Integer.parseHex(self, len)) |i| {
            result.r = @as(u8, @intCast(i.value));
        } else {
            self.setErr(.rgb_hex, 0, self.data.len - 1, 0);
            return null;
        }
        if (Integer.parseHex(self, len)) |i| {
            result.g = @as(u8, @intCast(i.value));
        } else {
            self.setErr(.rgb_hex, 0, self.data.len - 1, 0);
            return null;
        }
        if (Integer.parseHex(self, len)) |i| {
            result.b = @as(u8, @intCast(i.value));
        } else {
            self.setErr(.rgb_hex, 0, self.data.len - 1, 0);
            return null;
        }

        if (len == 1) {
            result.r = 16 * result.r + result.r;
            result.g = 16 * result.g + result.g;
            result.b = 16 * result.b + result.b;
        }

        return result;
    }

    fn parseIntPercent(self: *Parser) ?Value {
        if (self.data.len < 4 or !mem.eql(u8, self.data[0..4], "rgb(")) {
            self.setErr(.rgb_paren, 0, 0, 0);
            return null;
        }

        self.pos = 4;
        var result: Value = undefined;
        var percent = false;
        self.consumeWhitespace();
        var start = self.pos;
        if (Integer.parse(self)) |i| {
            percent = self.consumePercent();
            if (percent) {
                result.r = @intCast(@divFloor(255 * math.clamp(i.value, 0, 100), 100));
            } else {
                result.r = @intCast(math.clamp(i.value, 0, 255));
            }
        } else {
            self.setErr(.integer, start, self.pos, 0);
            return null;
        }

        if (!self.consumeCommaWhitespace()) {
            self.setErr(.comma, self.pos, self.pos, 0);
            return null;
        }

        start = self.pos;
        if (Integer.parse(self)) |i| {
            if (percent) {
                result.g = @intCast(@divFloor(255 * math.clamp(i.value, 0, 100), 100));
            } else {
                result.g = @intCast(math.clamp(i.value, 0, 255));
            }
        } else {
            self.setErr(.integer, start, self.pos, 0);
            return null;
        }

        if (percent) {
            if (!self.consumePercent()) {
                self.setErr(.percent, self.pos, self.pos, 0);
                return null;
            }
        }
        if (!self.consumeCommaWhitespace()) {
            self.setErr(.comma, self.pos, self.pos, 0);
            return null;
        }

        start = self.pos;
        if (Integer.parse(self)) |i| {
            if (percent) {
                result.b = @intCast(@divFloor(255 * math.clamp(i.value, 0, 100), 100));
            } else {
                result.b = @intCast(math.clamp(i.value, 0, 255));
            }
        } else {
            self.setErr(.integer, start, self.pos, 0);
            return null;
        }
        if (percent) {
            if (!self.consumePercent()) {
                self.setErr(.percent, self.pos, self.pos, 0);
                return null;
            }
        }

        self.consumeWhitespace();
        if (!self.consumeRParen()) {
            self.setErr(.right_paren, self.pos, self.pos, 0);
            return null;
        }

        return result;
    }

    fn parseName(name: []const u8) ?Value {
        // Color sources taken from W3C wiki:
        // https://www.w3.org/wiki/CSS/Properties/color/keywords
        if (mem.eql(u8, name, "aliceblue")) {
            return .{ .r = 240, .g = 248, .b = 255 };
        } else if (mem.eql(u8, name, "antiquewhite")) {
            return .{ .r = 250, .g = 235, .b = 215 };
        } else if (mem.eql(u8, name, "aqua")) {
            return .{ .r = 0, .g = 255, .b = 255 };
        } else if (mem.eql(u8, name, "aquamarine")) {
            return .{ .r = 127, .g = 255, .b = 212 };
        } else if (mem.eql(u8, name, "azure")) {
            return .{ .r = 240, .g = 255, .b = 255 };
        } else if (mem.eql(u8, name, "beige")) {
            return .{ .r = 245, .g = 245, .b = 220 };
        } else if (mem.eql(u8, name, "bisque")) {
            return .{ .r = 255, .g = 228, .b = 196 };
        } else if (mem.eql(u8, name, "black")) {
            return .{ .r = 0, .g = 0, .b = 0 };
        } else if (mem.eql(u8, name, "blanchedalmond")) {
            return .{ .r = 255, .g = 235, .b = 205 };
        } else if (mem.eql(u8, name, "blue")) {
            return .{ .r = 0, .g = 0, .b = 255 };
        } else if (mem.eql(u8, name, "blueviolet")) {
            return .{ .r = 138, .g = 43, .b = 226 };
        } else if (mem.eql(u8, name, "brown")) {
            return .{ .r = 165, .g = 42, .b = 42 };
        } else if (mem.eql(u8, name, "burlywood")) {
            return .{ .r = 222, .g = 184, .b = 135 };
        } else if (mem.eql(u8, name, "cadetblue")) {
            return .{ .r = 95, .g = 158, .b = 160 };
        } else if (mem.eql(u8, name, "chartreuse")) {
            return .{ .r = 127, .g = 255, .b = 0 };
        } else if (mem.eql(u8, name, "chocolate")) {
            return .{ .r = 210, .g = 105, .b = 30 };
        } else if (mem.eql(u8, name, "coral")) {
            return .{ .r = 255, .g = 127, .b = 80 };
        } else if (mem.eql(u8, name, "cornflowerblue")) {
            return .{ .r = 100, .g = 149, .b = 237 };
        } else if (mem.eql(u8, name, "cornsilk")) {
            return .{ .r = 255, .g = 248, .b = 220 };
        } else if (mem.eql(u8, name, "crimson")) {
            return .{ .r = 220, .g = 20, .b = 60 };
        } else if (mem.eql(u8, name, "cyan")) {
            return .{ .r = 0, .g = 255, .b = 255 };
        } else if (mem.eql(u8, name, "darkblue")) {
            return .{ .r = 0, .g = 0, .b = 139 };
        } else if (mem.eql(u8, name, "darkcyan")) {
            return .{ .r = 0, .g = 139, .b = 139 };
        } else if (mem.eql(u8, name, "darkgoldenrod")) {
            return .{ .r = 184, .g = 134, .b = 11 };
        } else if (mem.eql(u8, name, "darkgray")) {
            return .{ .r = 169, .g = 169, .b = 169 };
        } else if (mem.eql(u8, name, "darkgreen")) {
            return .{ .r = 0, .g = 100, .b = 0 };
        } else if (mem.eql(u8, name, "darkgrey")) {
            return .{ .r = 169, .g = 169, .b = 169 };
        } else if (mem.eql(u8, name, "darkkhaki")) {
            return .{ .r = 189, .g = 183, .b = 107 };
        } else if (mem.eql(u8, name, "darkmagenta")) {
            return .{ .r = 139, .g = 0, .b = 139 };
        } else if (mem.eql(u8, name, "darkolivegreen")) {
            return .{ .r = 85, .g = 107, .b = 47 };
        } else if (mem.eql(u8, name, "darkorange")) {
            return .{ .r = 255, .g = 140, .b = 0 };
        } else if (mem.eql(u8, name, "darkorchid")) {
            return .{ .r = 153, .g = 50, .b = 204 };
        } else if (mem.eql(u8, name, "darkred")) {
            return .{ .r = 139, .g = 0, .b = 0 };
        } else if (mem.eql(u8, name, "darksalmon")) {
            return .{ .r = 233, .g = 150, .b = 122 };
        } else if (mem.eql(u8, name, "darkseagreen")) {
            return .{ .r = 143, .g = 188, .b = 143 };
        } else if (mem.eql(u8, name, "darkslateblue")) {
            return .{ .r = 72, .g = 61, .b = 139 };
        } else if (mem.eql(u8, name, "darkslategray")) {
            return .{ .r = 47, .g = 79, .b = 79 };
        } else if (mem.eql(u8, name, "darkslategrey")) {
            return .{ .r = 47, .g = 79, .b = 79 };
        } else if (mem.eql(u8, name, "darkturquoise")) {
            return .{ .r = 0, .g = 206, .b = 209 };
        } else if (mem.eql(u8, name, "darkviolet")) {
            return .{ .r = 148, .g = 0, .b = 211 };
        } else if (mem.eql(u8, name, "deeppink")) {
            return .{ .r = 255, .g = 20, .b = 147 };
        } else if (mem.eql(u8, name, "deepskyblue")) {
            return .{ .r = 0, .g = 191, .b = 255 };
        } else if (mem.eql(u8, name, "dimgray")) {
            return .{ .r = 105, .g = 105, .b = 105 };
        } else if (mem.eql(u8, name, "dimgrey")) {
            return .{ .r = 105, .g = 105, .b = 105 };
        } else if (mem.eql(u8, name, "dodgerblue")) {
            return .{ .r = 30, .g = 144, .b = 255 };
        } else if (mem.eql(u8, name, "firebrick")) {
            return .{ .r = 178, .g = 34, .b = 34 };
        } else if (mem.eql(u8, name, "floralwhite")) {
            return .{ .r = 255, .g = 250, .b = 240 };
        } else if (mem.eql(u8, name, "forestgreen")) {
            return .{ .r = 34, .g = 139, .b = 34 };
        } else if (mem.eql(u8, name, "fuchsia")) {
            return .{ .r = 255, .g = 0, .b = 255 };
        } else if (mem.eql(u8, name, "gainsboro")) {
            return .{ .r = 220, .g = 220, .b = 220 };
        } else if (mem.eql(u8, name, "ghostwhite")) {
            return .{ .r = 248, .g = 248, .b = 255 };
        } else if (mem.eql(u8, name, "goldenrod")) {
            return .{ .r = 218, .g = 165, .b = 32 };
        } else if (mem.eql(u8, name, "gold")) {
            return .{ .r = 255, .g = 215, .b = 0 };
        } else if (mem.eql(u8, name, "gray")) {
            return .{ .r = 128, .g = 128, .b = 128 };
        } else if (mem.eql(u8, name, "green")) {
            return .{ .r = 0, .g = 128, .b = 0 };
        } else if (mem.eql(u8, name, "greenyellow")) {
            return .{ .r = 173, .g = 255, .b = 47 };
        } else if (mem.eql(u8, name, "grey")) {
            return .{ .r = 128, .g = 128, .b = 128 };
        } else if (mem.eql(u8, name, "honeydew")) {
            return .{ .r = 240, .g = 255, .b = 240 };
        } else if (mem.eql(u8, name, "hotpink")) {
            return .{ .r = 255, .g = 105, .b = 180 };
        } else if (mem.eql(u8, name, "indianred")) {
            return .{ .r = 205, .g = 92, .b = 92 };
        } else if (mem.eql(u8, name, "indigo")) {
            return .{ .r = 75, .g = 0, .b = 130 };
        } else if (mem.eql(u8, name, "ivory")) {
            return .{ .r = 255, .g = 255, .b = 240 };
        } else if (mem.eql(u8, name, "khaki")) {
            return .{ .r = 240, .g = 230, .b = 140 };
        } else if (mem.eql(u8, name, "lavenderblush")) {
            return .{ .r = 255, .g = 240, .b = 245 };
        } else if (mem.eql(u8, name, "lavender")) {
            return .{ .r = 230, .g = 230, .b = 250 };
        } else if (mem.eql(u8, name, "lawngreen")) {
            return .{ .r = 124, .g = 252, .b = 0 };
        } else if (mem.eql(u8, name, "lemonchiffon")) {
            return .{ .r = 255, .g = 250, .b = 205 };
        } else if (mem.eql(u8, name, "lightblue")) {
            return .{ .r = 173, .g = 216, .b = 230 };
        } else if (mem.eql(u8, name, "lightcoral")) {
            return .{ .r = 240, .g = 128, .b = 128 };
        } else if (mem.eql(u8, name, "lightcyan")) {
            return .{ .r = 224, .g = 255, .b = 255 };
        } else if (mem.eql(u8, name, "lightgoldenrodyellow")) {
            return .{ .r = 250, .g = 250, .b = 210 };
        } else if (mem.eql(u8, name, "lightgray")) {
            return .{ .r = 211, .g = 211, .b = 211 };
        } else if (mem.eql(u8, name, "lightgreen")) {
            return .{ .r = 144, .g = 238, .b = 144 };
        } else if (mem.eql(u8, name, "lightgrey")) {
            return .{ .r = 211, .g = 211, .b = 211 };
        } else if (mem.eql(u8, name, "lightpink")) {
            return .{ .r = 255, .g = 182, .b = 193 };
        } else if (mem.eql(u8, name, "lightsalmon")) {
            return .{ .r = 255, .g = 160, .b = 122 };
        } else if (mem.eql(u8, name, "lightseagreen")) {
            return .{ .r = 32, .g = 178, .b = 170 };
        } else if (mem.eql(u8, name, "lightskyblue")) {
            return .{ .r = 135, .g = 206, .b = 250 };
        } else if (mem.eql(u8, name, "lightslategray")) {
            return .{ .r = 119, .g = 136, .b = 153 };
        } else if (mem.eql(u8, name, "lightslategrey")) {
            return .{ .r = 119, .g = 136, .b = 153 };
        } else if (mem.eql(u8, name, "lightsteelblue")) {
            return .{ .r = 176, .g = 196, .b = 222 };
        } else if (mem.eql(u8, name, "lightyellow")) {
            return .{ .r = 255, .g = 255, .b = 224 };
        } else if (mem.eql(u8, name, "lime")) {
            return .{ .r = 0, .g = 255, .b = 0 };
        } else if (mem.eql(u8, name, "limegreen")) {
            return .{ .r = 50, .g = 205, .b = 50 };
        } else if (mem.eql(u8, name, "linen")) {
            return .{ .r = 250, .g = 240, .b = 230 };
        } else if (mem.eql(u8, name, "magenta")) {
            return .{ .r = 255, .g = 0, .b = 255 };
        } else if (mem.eql(u8, name, "maroon")) {
            return .{ .r = 128, .g = 0, .b = 0 };
        } else if (mem.eql(u8, name, "mediumaquamarine")) {
            return .{ .r = 102, .g = 205, .b = 170 };
        } else if (mem.eql(u8, name, "mediumblue")) {
            return .{ .r = 0, .g = 0, .b = 205 };
        } else if (mem.eql(u8, name, "mediumorchid")) {
            return .{ .r = 186, .g = 85, .b = 211 };
        } else if (mem.eql(u8, name, "mediumpurple")) {
            return .{ .r = 147, .g = 112, .b = 219 };
        } else if (mem.eql(u8, name, "mediumseagreen")) {
            return .{ .r = 60, .g = 179, .b = 113 };
        } else if (mem.eql(u8, name, "mediumslateblue")) {
            return .{ .r = 123, .g = 104, .b = 238 };
        } else if (mem.eql(u8, name, "mediumspringgreen")) {
            return .{ .r = 0, .g = 250, .b = 154 };
        } else if (mem.eql(u8, name, "mediumturquoise")) {
            return .{ .r = 72, .g = 209, .b = 204 };
        } else if (mem.eql(u8, name, "mediumvioletred")) {
            return .{ .r = 199, .g = 21, .b = 133 };
        } else if (mem.eql(u8, name, "midnightblue")) {
            return .{ .r = 25, .g = 25, .b = 112 };
        } else if (mem.eql(u8, name, "mintcream")) {
            return .{ .r = 245, .g = 255, .b = 250 };
        } else if (mem.eql(u8, name, "mistyrose")) {
            return .{ .r = 255, .g = 228, .b = 225 };
        } else if (mem.eql(u8, name, "moccasin")) {
            return .{ .r = 255, .g = 228, .b = 181 };
        } else if (mem.eql(u8, name, "navajowhite")) {
            return .{ .r = 255, .g = 222, .b = 173 };
        } else if (mem.eql(u8, name, "navy")) {
            return .{ .r = 0, .g = 0, .b = 128 };
        } else if (mem.eql(u8, name, "oldlace")) {
            return .{ .r = 253, .g = 245, .b = 230 };
        } else if (mem.eql(u8, name, "olive")) {
            return .{ .r = 128, .g = 128, .b = 0 };
        } else if (mem.eql(u8, name, "olivedrab")) {
            return .{ .r = 107, .g = 142, .b = 35 };
        } else if (mem.eql(u8, name, "orange")) {
            return .{ .r = 255, .g = 165, .b = 0 };
        } else if (mem.eql(u8, name, "orangered")) {
            return .{ .r = 255, .g = 69, .b = 0 };
        } else if (mem.eql(u8, name, "orchid")) {
            return .{ .r = 218, .g = 112, .b = 214 };
        } else if (mem.eql(u8, name, "palegoldenrod")) {
            return .{ .r = 238, .g = 232, .b = 170 };
        } else if (mem.eql(u8, name, "palegreen")) {
            return .{ .r = 152, .g = 251, .b = 152 };
        } else if (mem.eql(u8, name, "paleturquoise")) {
            return .{ .r = 175, .g = 238, .b = 238 };
        } else if (mem.eql(u8, name, "palevioletred")) {
            return .{ .r = 219, .g = 112, .b = 147 };
        } else if (mem.eql(u8, name, "papayawhip")) {
            return .{ .r = 255, .g = 239, .b = 213 };
        } else if (mem.eql(u8, name, "peachpuff")) {
            return .{ .r = 255, .g = 218, .b = 185 };
        } else if (mem.eql(u8, name, "peru")) {
            return .{ .r = 205, .g = 133, .b = 63 };
        } else if (mem.eql(u8, name, "pink")) {
            return .{ .r = 255, .g = 192, .b = 203 };
        } else if (mem.eql(u8, name, "plum")) {
            return .{ .r = 221, .g = 160, .b = 221 };
        } else if (mem.eql(u8, name, "powderblue")) {
            return .{ .r = 176, .g = 224, .b = 230 };
        } else if (mem.eql(u8, name, "purple")) {
            return .{ .r = 128, .g = 0, .b = 128 };
        } else if (mem.eql(u8, name, "red")) {
            return .{ .r = 255, .g = 0, .b = 0 };
        } else if (mem.eql(u8, name, "rosybrown")) {
            return .{ .r = 188, .g = 143, .b = 143 };
        } else if (mem.eql(u8, name, "royalblue")) {
            return .{ .r = 65, .g = 105, .b = 225 };
        } else if (mem.eql(u8, name, "saddlebrown")) {
            return .{ .r = 139, .g = 69, .b = 19 };
        } else if (mem.eql(u8, name, "salmon")) {
            return .{ .r = 250, .g = 128, .b = 114 };
        } else if (mem.eql(u8, name, "sandybrown")) {
            return .{ .r = 244, .g = 164, .b = 96 };
        } else if (mem.eql(u8, name, "seagreen")) {
            return .{ .r = 46, .g = 139, .b = 87 };
        } else if (mem.eql(u8, name, "seashell")) {
            return .{ .r = 255, .g = 245, .b = 238 };
        } else if (mem.eql(u8, name, "sienna")) {
            return .{ .r = 160, .g = 82, .b = 45 };
        } else if (mem.eql(u8, name, "silver")) {
            return .{ .r = 192, .g = 192, .b = 192 };
        } else if (mem.eql(u8, name, "skyblue")) {
            return .{ .r = 135, .g = 206, .b = 235 };
        } else if (mem.eql(u8, name, "slateblue")) {
            return .{ .r = 106, .g = 90, .b = 205 };
        } else if (mem.eql(u8, name, "slategray")) {
            return .{ .r = 112, .g = 128, .b = 144 };
        } else if (mem.eql(u8, name, "slategrey")) {
            return .{ .r = 112, .g = 128, .b = 144 };
        } else if (mem.eql(u8, name, "snow")) {
            return .{ .r = 255, .g = 250, .b = 250 };
        } else if (mem.eql(u8, name, "springgreen")) {
            return .{ .r = 0, .g = 255, .b = 127 };
        } else if (mem.eql(u8, name, "steelblue")) {
            return .{ .r = 70, .g = 130, .b = 180 };
        } else if (mem.eql(u8, name, "tan")) {
            return .{ .r = 210, .g = 180, .b = 140 };
        } else if (mem.eql(u8, name, "teal")) {
            return .{ .r = 0, .g = 128, .b = 128 };
        } else if (mem.eql(u8, name, "thistle")) {
            return .{ .r = 216, .g = 191, .b = 216 };
        } else if (mem.eql(u8, name, "tomato")) {
            return .{ .r = 255, .g = 99, .b = 71 };
        } else if (mem.eql(u8, name, "turquoise")) {
            return .{ .r = 64, .g = 224, .b = 208 };
        } else if (mem.eql(u8, name, "violet")) {
            return .{ .r = 238, .g = 130, .b = 238 };
        } else if (mem.eql(u8, name, "wheat")) {
            return .{ .r = 245, .g = 222, .b = 179 };
        } else if (mem.eql(u8, name, "white")) {
            return .{ .r = 255, .g = 255, .b = 255 };
        } else if (mem.eql(u8, name, "whitesmoke")) {
            return .{ .r = 245, .g = 245, .b = 245 };
        } else if (mem.eql(u8, name, "yellow")) {
            return .{ .r = 255, .g = 255, .b = 0 };
        } else if (mem.eql(u8, name, "yellowgreen")) {
            return .{ .r = 154, .g = 205, .b = 50 };
        }

        return null;
    }
};

/// Represents a CSS2 length value, based on the standard of 96 pixels/user
/// units per inch. In our nomenclature, a pixel is the same as a user unit.
pub const Length = struct {
    parser: Parser,
    number: Number,
    unit: Unit,

    const Unit = enum {
        em,
        ex,
        px,
        in,
        cm,
        mm,
        pt,
        pc,
        percent,
    };

    /// Returns the value of the length as pixels.
    ///
    /// relative_px needs to be supplied to get meaningful values out of em,
    /// ex, and percent units.
    pub fn toPixels(self: *const Length, relative_px: f64) f64 {
        return switch (self.unit) {
            .em => self.number.value * relative_px,
            .ex => self.number.value * relative_px,
            .px => self.number.value,
            .in => self.number.value * 96,
            .cm => self.number.value / 2.54 * 96,
            .mm => self.number.value / 25.4 * 96,
            .pt => self.number.value / 72 * 96,
            .pc => self.number.value * 12 / 72 * 96,
            .percent => self.number.value / 100 * relative_px,
        };
    }

    /// Parses a CSS2 length value.
    ///
    /// This should be used for length values contained in normal presentation
    /// attributes. To parse length values contained in `style` attributes, use
    /// `parseStyle`.
    pub fn parse(data: []const u8) Length {
        var result: Length = .{
            .parser = .{ .data = data },
            .number = .{ .value = 0, .pos = .{ .start = 0, .end = 0 } },
            .unit = .px,
        };

        if (Number.parse(&result.parser)) |v| {
            result.number = v;
        } else {
            result.parser.setErr(.number, 0, result.parser.pos, 0);
            return result;
        }

        if (parseUnitPresentiation(result.parser.data[result.parser.pos..])) |parsed| {
            result.parser.pos = result.parser.data.len;
            result.unit = parsed;
        } else {
            result.parser.setErr(
                .presentation_length_unit,
                result.parser.pos,
                result.parser.data.len - 1,
                result.parser.pos,
            );
        }

        return result;
    }

    /// Parses a CSS2 length value.
    ///
    /// This should be used for length values contained in `style` attributes.
    /// To parse length values contained in presentation attributes, use
    /// `parse`.
    pub fn parseStyle(data: []const u8) Length {
        var result: Length = .{
            .parser = .{ .data = data },
            .number = .{ .value = 0, .pos = .{ .start = 0, .end = 0 } },
            .unit = .px,
        };

        if (Number.parse(&result.parser)) |v| {
            result.number = v;
        } else {
            result.parser.setErr(.number, 0, result.parser.pos, 0);
            return result;
        }

        if (parseUnitStyle(result.parser.data[result.parser.pos..])) |parsed| {
            result.parser.pos = result.parser.data.len;
            result.unit = parsed;
        } else {
            result.parser.setErr(
                .style_length_unit,
                result.parser.pos,
                result.parser.data.len - 1,
                result.parser.pos,
            );
        }

        return result;
    }

    fn parseUnitStyle(value: []const u8) ?Unit {
        if (value.len == 0) {
            return .px;
        } else if (mem.eql(u8, value, "em")) {
            return .em;
        } else if (mem.eql(u8, value, "eM")) {
            return .em;
        } else if (mem.eql(u8, value, "Em")) {
            return .em;
        } else if (mem.eql(u8, value, "EM")) {
            return .em;
        } else if (mem.eql(u8, value, "ex")) {
            return .ex;
        } else if (mem.eql(u8, value, "eX")) {
            return .ex;
        } else if (mem.eql(u8, value, "Ex")) {
            return .ex;
        } else if (mem.eql(u8, value, "EX")) {
            return .ex;
        } else if (mem.eql(u8, value, "px")) {
            return .px;
        } else if (mem.eql(u8, value, "pX")) {
            return .px;
        } else if (mem.eql(u8, value, "Px")) {
            return .px;
        } else if (mem.eql(u8, value, "PX")) {
            return .px;
        } else if (mem.eql(u8, value, "in")) {
            return .in;
        } else if (mem.eql(u8, value, "iN")) {
            return .in;
        } else if (mem.eql(u8, value, "In")) {
            return .in;
        } else if (mem.eql(u8, value, "IN")) {
            return .in;
        } else if (mem.eql(u8, value, "cm")) {
            return .cm;
        } else if (mem.eql(u8, value, "cM")) {
            return .cm;
        } else if (mem.eql(u8, value, "Cm")) {
            return .cm;
        } else if (mem.eql(u8, value, "CM")) {
            return .cm;
        } else if (mem.eql(u8, value, "mm")) {
            return .mm;
        } else if (mem.eql(u8, value, "mM")) {
            return .mm;
        } else if (mem.eql(u8, value, "Mm")) {
            return .mm;
        } else if (mem.eql(u8, value, "MM")) {
            return .mm;
        } else if (mem.eql(u8, value, "pt")) {
            return .pt;
        } else if (mem.eql(u8, value, "pT")) {
            return .pt;
        } else if (mem.eql(u8, value, "Pt")) {
            return .pt;
        } else if (mem.eql(u8, value, "PT")) {
            return .pt;
        } else if (mem.eql(u8, value, "pc")) {
            return .pc;
        } else if (mem.eql(u8, value, "pC")) {
            return .pc;
        } else if (mem.eql(u8, value, "Pc")) {
            return .pc;
        } else if (mem.eql(u8, value, "PC")) {
            return .pc;
        }

        return null;
    }

    fn parseUnitPresentiation(value: []const u8) ?Unit {
        if (value.len == 0) {
            return .px;
        } else if (mem.eql(u8, value, "em")) {
            return .em;
        } else if (mem.eql(u8, value, "ex")) {
            return .ex;
        } else if (mem.eql(u8, value, "px")) {
            return .px;
        } else if (mem.eql(u8, value, "in")) {
            return .in;
        } else if (mem.eql(u8, value, "cm")) {
            return .cm;
        } else if (mem.eql(u8, value, "mm")) {
            return .mm;
        } else if (mem.eql(u8, value, "pt")) {
            return .pt;
        } else if (mem.eql(u8, value, "pc")) {
            return .pc;
        } else if (mem.eql(u8, value, "%")) {
            return .percent;
        }

        return null;
    }
};

/// Represents a co-ordinate pair (e.g., x,y).
pub const CoordinatePair = struct {
    coordinates: [2]Coordinate,
    pos: Parser.Pos,

    fn parse(self: *Parser) ?CoordinatePair {
        const reset = self.pos;
        var result: CoordinatePair = undefined;
        if (Coordinate.parse(self)) |c| {
            result.coordinates[0] = c;
            result.pos.start = c.pos.start;
        } else {
            self.setErr(.coordinate_pair, reset, self.pos, reset);
            return null;
        }

        _ = self.consumeCommaWhitespace();

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

/// Represents a single co-ordinate, usually expected as part of a co-ordinate
/// pair, or singular for the horizontal or vertical line commands.
pub const Coordinate = struct {
    number: Number,
    pos: Parser.Pos,

    fn parse(self: *Parser) ?Coordinate {
        if (Number.parse(self)) |n| {
            return .{
                .number = n,
                .pos = n.pos,
            };
        }

        return null;
    }
};

/// Represents a flag (0 or 1).
pub const Flag = struct {
    value: bool,
    pos: Parser.Pos,

    fn parse(self: *Parser) ?Flag {
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

/// Represents an IEEE-754 double-precision floating point number.
///
/// Note that values are stored fully parsed including sign and exponent. For
/// details of how the number was actually expressed, check the unparsed data
/// against the position data reported.
pub const Number = struct {
    value: f64,
    pos: Parser.Pos,

    fn parse(self: *Parser) ?Number {
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
        var pos: ?Parser.Pos = null;

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
            const val = fmt.parseFloat(f64, self.data[p.start .. p.end + 1]) catch return null;
            return .{
                .value = val,
                .pos = p,
            };
        }

        return null;
    }
};

/// Represents a signed integer between -2147483648 and 2147483647.
pub const Integer = struct {
    value: i32,
    pos: Parser.Pos,

    fn parse(self: *Parser) ?Integer {
        var ctx: enum {
            int_invalid,
            int_sign,
            int,
        } = .int_invalid;
        var pos: ?Parser.Pos = null;

        while (self.pos < self.data.len) : (self.pos += 1) {
            switch (self.data[self.pos]) {
                '+', '-' => switch (ctx) {
                    .int_invalid => ctx = .int_sign,
                    else => break,
                },
                '0'...'9' => switch (ctx) {
                    .int_invalid, .int_sign => ctx = .int,
                    .int,
                    => {},
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
                .int_sign => {
                    p.end -= 1;
                    self.pos -= 1;
                },
                else => {},
            }
            if (p.end < p.start) {
                return null;
            }
            const val = fmt.parseInt(i32, self.data[p.start .. p.end + 1], 0) catch return null;
            return .{
                .value = val,
                .pos = p,
            };
        }

        return null;
    }

    fn parseHex(self: *Parser, len: usize) ?Integer {
        var pos: ?Parser.Pos = null;
        const end = self.pos + len;

        while (self.pos < self.data.len and self.pos < end) : (self.pos += 1) {
            switch (self.data[self.pos]) {
                '0'...'9', 'A'...'F', 'a'...'f' => {},
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

        if (pos) |p| {
            const val = fmt.parseInt(i32, self.data[p.start .. p.end + 1], 16) catch return null;
            return .{
                .value = val,
                .pos = p,
            };
        }

        return null;
    }
};

/// A parser, usually embedded in various returned top-level primitives (e.g.,
/// `Path` or `Color`).
///
/// You should not need to manipulate the parser directly; it's exposed so that
/// you can consult the err value within and access other types like `Pos` and
/// `Error`.
pub const Parser = struct {
    data: []const u8,
    pos: usize = 0,
    err: ?Error = null,

    /// The character position in the data for a particular element, zero indexed.
    pub const Pos = struct {
        start: usize,
        end: usize,
    };

    /// Represents an error encountered during parsing.
    pub const Error = struct {
        expected: Expected,
        pos: Pos,

        pub const Expected = enum {
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
            color_keyword,
            comma,
            coordinate_pair,
            drawto_command,
            flag,
            hash,
            integer,
            moveto_command,
            nonnegative_number,
            number,
            percent,
            presentation_length_unit,
            style_length_unit,
            rgb_hex,
            rgb_paren,
            right_paren,

            pub fn string(self: Expected) []const u8 {
                return switch (self) {
                    .A_or_a => "'A' or 'a'",
                    .C_or_c => "'C' or 'c'",
                    .H_or_h => "'H' or 'h'",
                    .L_or_l => "'L' or 'l'",
                    .M_or_m, .moveto_command => "'M' or 'm'",
                    .Q_or_q => "'Q' or 'q'",
                    .S_or_s => "'S' or 's'",
                    .T_or_t => "'T' or 't'",
                    .V_or_v => "'V' or 'v'",
                    .Z_or_z => "'Z' or 'z'",
                    .color_keyword => "color keyword",
                    .comma => "','",
                    .coordinate_pair => "coordinate pair",
                    .drawto_command => "draw command [ACHLMQSTVZachlmqstvz]",
                    .flag => "'0' or '1'",
                    .hash => "'#'",
                    .integer => "integer",
                    .nonnegative_number => "non-negative number",
                    .number => "number",
                    .percent => "'%'",
                    .presentation_length_unit => "case-sensitive length unit or '%'",
                    .style_length_unit => "case-insensitive length unit",
                    .rgb_hex => "RGB hex pattern (#RGB or #RRGGBB)",
                    .rgb_paren => "'rgb('",
                    .right_paren => "')'",
                };
            }
        };
    };

    /// Prints the error to the supplied writer.
    pub fn fmtErr(self: *Parser, writer: anytype) !void {
        if (self.err) |e| {
            try fmt.format(
                writer,
                "at pos {d}: expected {s}, found ",
                .{
                    if (e.pos.start < self.data.len) e.pos.start + 1 else self.data.len,
                    e.expected.string(),
                },
            );
            if (e.pos.start < self.data.len) {
                try fmt.format(writer, "'{s}'\n", .{self.data[e.pos.start .. e.pos.end + 1]});
            } else {
                try fmt.format(writer, "end of data\n", .{});
            }
        }
    }

    /// Renders the error; the returned slice is allocated with the supplied
    /// allocator and is owned by the caller.
    ///
    /// Note that this does not render newlines.
    pub fn allocPrintErr(self: *Parser, alloc: mem.Allocator) ![]const u8 {
        if (self.err) |e| {
            if (e.pos.start < self.data.len) {
                return fmt.allocPrint(
                    alloc,
                    "at pos {d}: expected {s}, found '{s}'",
                    .{
                        if (e.pos.start < self.data.len) e.pos.start + 1 else self.data.len,
                        e.expected.string(),
                        self.data[e.pos.start .. e.pos.end + 1],
                    },
                );
            } else {
                return fmt.allocPrint(
                    alloc,
                    "at pos {d}: expected {s}, found end of data",
                    .{
                        if (e.pos.start < self.data.len) e.pos.start + 1 else self.data.len,
                        e.expected.string(),
                    },
                );
            }
        }

        return alloc.alloc(u8, 0);
    }

    fn setErr(self: *Parser, expected: Error.Expected, start: usize, end: usize, reset: usize) void {
        self.err = .{ .expected = expected, .pos = .{ .start = start, .end = end } };
        self.pos = reset;
    }

    fn consumeCommaWhitespace(self: *Parser) bool {
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

        return hasComma;
    }

    fn consumeWhitespace(self: *Parser) void {
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

    fn consumePercent(self: *Parser) bool {
        var hasPercent = false;
        while (self.pos < self.data.len) : (self.pos += 1) {
            switch (self.data[self.pos]) {
                '%' => {
                    if (hasPercent) break;
                    hasPercent = true;
                },
                else => break,
            }
        }

        return hasPercent;
    }

    fn consumeRParen(self: *Parser) bool {
        var hasParen = false;
        while (self.pos < self.data.len) : (self.pos += 1) {
            switch (self.data[self.pos]) {
                ')' => {
                    if (hasParen) break;
                    hasParen = true;
                },
                else => break,
            }
        }

        return hasParen;
    }
};

test "Length.parse and parseStyle" {
    {
        // em
        const got = Length.parse("1.2em");
        try testing.expectEqual(null, got.parser.err);
        try testing.expectEqual(1.2, got.number.value);
        try testing.expectEqual(.em, got.unit);
        try testing.expectEqual(5, got.parser.pos);
    }

    {
        // em (style)
        const got = Length.parseStyle("1.2eM");
        try testing.expectEqual(null, got.parser.err);
        try testing.expectEqual(1.2, got.number.value);
        try testing.expectEqual(.em, got.unit);
        try testing.expectEqual(5, got.parser.pos);
    }

    {
        // px
        const got = Length.parse("1.2px");
        try testing.expectEqual(null, got.parser.err);
        try testing.expectEqual(1.2, got.number.value);
        try testing.expectEqual(.px, got.unit);
        try testing.expectEqual(5, got.parser.pos);
    }

    {
        // percent
        const got = Length.parse("1.2%");
        try testing.expectEqual(null, got.parser.err);
        try testing.expectEqual(1.2, got.number.value);
        try testing.expectEqual(.percent, got.unit);
        try testing.expectEqual(4, got.parser.pos);
    }

    {
        // user units (px)
        const got = Length.parse("1.2");
        try testing.expectEqual(null, got.parser.err);
        try testing.expectEqual(1.2, got.number.value);
        try testing.expectEqual(.px, got.unit);
        try testing.expectEqual(3, got.parser.pos);
    }

    {
        // Invalid (number expected)
        var got = Length.parse("bad");
        try testing.expectEqual(.number, got.parser.err.?.expected);
        try testing.expectEqual(0, got.parser.err.?.pos.start);
        try testing.expectEqual(0, got.parser.err.?.pos.end);
        try testing.expectEqual(0, got.parser.pos);
        try testError(&got.parser, "at pos 1: expected number, found 'b'\n");
    }

    {
        // Invalid (invalid unit)
        var got = Length.parse("1bad");
        try testing.expectEqual(.presentation_length_unit, got.parser.err.?.expected);
        try testing.expectEqual(1, got.parser.err.?.pos.start);
        try testing.expectEqual(3, got.parser.err.?.pos.end);
        try testing.expectEqual(1, got.parser.pos);
        try testError(&got.parser, "at pos 2: expected case-sensitive length unit or '%', found 'bad'\n");
    }

    {
        // Invalid ('%' not allowed when parsing style units)
        var got = Length.parseStyle("1%");
        try testing.expectEqual(.style_length_unit, got.parser.err.?.expected);
        try testing.expectEqual(1, got.parser.err.?.pos.start);
        try testing.expectEqual(1, got.parser.err.?.pos.end);
        try testing.expectEqual(1, got.parser.pos);
        try testError(&got.parser, "at pos 2: expected case-insensitive length unit, found '%'\n");
    }
}

test "Length.toPixels" {
    {
        // em
        const got = Length.parse("1.2em");
        try testing.expectEqual(null, got.parser.err);
        try testing.expectEqual(12, got.toPixels(10));
    }

    {
        // ex
        const got = Length.parse("1.2ex");
        try testing.expectEqual(null, got.parser.err);
        try testing.expectEqual(12, got.toPixels(10));
    }

    {
        // px
        const got = Length.parse("999px");
        try testing.expectEqual(null, got.parser.err);
        try testing.expectEqual(999, got.toPixels(10));
    }

    {
        // in
        const got = Length.parse("2in");
        try testing.expectEqual(null, got.parser.err);
        try testing.expectEqual(192, got.toPixels(10));
    }

    {
        // cm
        const got = Length.parse("100cm");
        try testing.expectEqual(null, got.parser.err);
        try testing.expectEqual(3779.52755905511811023616, got.toPixels(10));
    }

    {
        // mm
        const got = Length.parse("254mm");
        try testing.expectEqual(null, got.parser.err);
        try testing.expectEqual(960, got.toPixels(10));
    }

    {
        // pt
        const got = Length.parse("72pt");
        try testing.expectEqual(null, got.parser.err);
        try testing.expectEqual(96, got.toPixels(10));
    }

    {
        // pt
        const got = Length.parse("6pc");
        try testing.expectEqual(null, got.parser.err);
        try testing.expectEqual(96, got.toPixels(10));
    }

    {
        // percent
        const got = Length.parse("10%");
        try testing.expectEqual(null, got.parser.err);
        try testing.expectEqual(10, got.toPixels(100));
    }
}

test "Color.parse" {
    {
        // Hex
        const got = Color.parse("#1a2b3c");
        try testing.expectEqual(null, got.parser.err);
        try testing.expectEqual(Color.Value{ .r = 26, .g = 43, .b = 60 }, got.value);
        try testing.expectEqual(7, got.parser.pos);
    }

    {
        // Int
        const got = Color.parse("rgb(11, 22, 33)");
        try testing.expectEqual(null, got.parser.err);
        try testing.expectEqual(Color.Value{ .r = 11, .g = 22, .b = 33 }, got.value);
        try testing.expectEqual(15, got.parser.pos);
    }

    {
        // Percent
        const got = Color.parse("rgb(33%, 66%, 99%)");
        try testing.expectEqual(null, got.parser.err);
        try testing.expectEqual(Color.Value{ .r = 84, .g = 168, .b = 252 }, got.value);
        try testing.expectEqual(18, got.parser.pos);
    }

    {
        // Name
        const got = Color.parse("coral");
        try testing.expectEqual(null, got.parser.err);
        try testing.expectEqual(Color.Value{ .r = 255, .g = 127, .b = 80 }, got.value);
        try testing.expectEqual(5, got.parser.pos);
    }
    {
        // Invalid
        var got = Color.parse("bad");
        try testing.expectEqual(.color_keyword, got.parser.err.?.expected);
        try testing.expectEqual(0, got.parser.err.?.pos.start);
        try testing.expectEqual(2, got.parser.err.?.pos.end);
        try testing.expectEqual(0, got.parser.pos);
        try testError(&got.parser, "at pos 1: expected color keyword, found 'bad'\n");
    }
}

test "Color.parseHex" {
    {
        // Basic (len 1)
        var parser: Parser = .{ .data = "#abc" };
        const got = Color.parseHex(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(Color.Value{ .r = 170, .g = 187, .b = 204 }, got);
    }

    {
        // Basic (len 2)
        var parser: Parser = .{ .data = "#1a2b3c" };
        const got = Color.parseHex(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(Color.Value{ .r = 26, .g = 43, .b = 60 }, got);
    }

    {
        // Basic (alt caps)
        var parser: Parser = .{ .data = "#1A2b3C" };
        const got = Color.parseHex(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(Color.Value{ .r = 26, .g = 43, .b = 60 }, got);
    }

    {
        // Error (missing "#")
        //
        // Note that we assert this on reading the production, but it should
        // never come up in real-world use.
        var parser: Parser = .{ .data = "aabbcc" };
        try testing.expectEqual(null, Color.parseHex(&parser));
        try testing.expectEqual(.hash, parser.err.?.expected);
        try testing.expectEqual(0, parser.err.?.pos.start);
        try testing.expectEqual(0, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at pos 1: expected '#', found 'a'\n");
    }

    {
        // Error (invalid len)
        var parser: Parser = .{ .data = "#aabbc" };
        try testing.expectEqual(null, Color.parseHex(&parser));
        try testing.expectEqual(.rgb_hex, parser.err.?.expected);
        try testing.expectEqual(0, parser.err.?.pos.start);
        try testing.expectEqual(5, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at pos 1: expected RGB hex pattern (#RGB or #RRGGBB), found '#aabbc'\n");
    }

    {
        // Error (bad int in pos 1)
        var parser: Parser = .{ .data = "#zbc" };
        try testing.expectEqual(null, Color.parseHex(&parser));
        try testing.expectEqual(.rgb_hex, parser.err.?.expected);
        try testing.expectEqual(0, parser.err.?.pos.start);
        try testing.expectEqual(3, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at pos 1: expected RGB hex pattern (#RGB or #RRGGBB), found '#zbc'\n");
    }

    {
        // Error (bad int in pos 2)
        var parser: Parser = .{ .data = "#azc" };
        try testing.expectEqual(null, Color.parseHex(&parser));
        try testing.expectEqual(.rgb_hex, parser.err.?.expected);
        try testing.expectEqual(0, parser.err.?.pos.start);
        try testing.expectEqual(3, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at pos 1: expected RGB hex pattern (#RGB or #RRGGBB), found '#azc'\n");
    }

    {
        // Error (bad int in pos 3)
        var parser: Parser = .{ .data = "#abz" };
        try testing.expectEqual(null, Color.parseHex(&parser));
        try testing.expectEqual(.rgb_hex, parser.err.?.expected);
        try testing.expectEqual(0, parser.err.?.pos.start);
        try testing.expectEqual(3, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at pos 1: expected RGB hex pattern (#RGB or #RRGGBB), found '#abz'\n");
    }
}

test "Color.parseIntPercent" {
    {
        // Basic
        var parser: Parser = .{ .data = "rgb(11, 22, 33)" };
        const got = Color.parseIntPercent(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(Color.Value{ .r = 11, .g = 22, .b = 33 }, got);
    }

    {
        // Percent
        var parser: Parser = .{ .data = "rgb(33%, 66%, 99%)" };
        const got = Color.parseIntPercent(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(Color.Value{ .r = 84, .g = 168, .b = 252 }, got);
    }

    {
        // Percent (w/some whitespace)
        var parser: Parser = .{ .data = "rgb(  33% ,66% , 99%)" };
        const got = Color.parseIntPercent(&parser);
        try testing.expectEqual(null, parser.err);
        try testing.expectEqual(Color.Value{ .r = 84, .g = 168, .b = 252 }, got);
    }

    {
        // Error (missing "rgb(" )
        //
        // Note that we assert this on reading the production, but it should
        // never come up in real-world use.
        var parser: Parser = .{ .data = "33%,66%,99%" };
        try testing.expectEqual(null, Color.parseIntPercent(&parser));
        try testing.expectEqual(.rgb_paren, parser.err.?.expected);
        try testing.expectEqual(0, parser.err.?.pos.start);
        try testing.expectEqual(0, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at pos 1: expected 'rgb(', found '3'\n");
    }

    {
        // Error (just "rgb(" )
        var parser: Parser = .{ .data = "rgb(" };
        try testing.expectEqual(null, Color.parseIntPercent(&parser));
        try testing.expectEqual(.integer, parser.err.?.expected);
        try testing.expectEqual(4, parser.err.?.pos.start);
        try testing.expectEqual(4, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at pos 4: expected integer, found end of data\n");
    }

    {
        // Error (no closing ")" )
        var parser: Parser = .{ .data = "rgb(1,2,3" };
        try testing.expectEqual(null, Color.parseIntPercent(&parser));
        try testing.expectEqual(.right_paren, parser.err.?.expected);
        try testing.expectEqual(9, parser.err.?.pos.start);
        try testing.expectEqual(9, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at pos 9: expected ')', found end of data\n");
    }

    {
        // Error (missing number)
        var parser: Parser = .{ .data = "rgb(1,,3)" };
        try testing.expectEqual(null, Color.parseIntPercent(&parser));
        try testing.expectEqual(.integer, parser.err.?.expected);
        try testing.expectEqual(6, parser.err.?.pos.start);
        try testing.expectEqual(6, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at pos 7: expected integer, found ','\n");
    }

    {
        // Error (missing comma)
        var parser: Parser = .{ .data = "rgb(1 2,3)" };
        try testing.expectEqual(null, Color.parseIntPercent(&parser));
        try testing.expectEqual(.comma, parser.err.?.expected);
        try testing.expectEqual(6, parser.err.?.pos.start);
        try testing.expectEqual(6, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at pos 7: expected ',', found '2'\n");
    }

    {
        // Error (inconsistent % usage)
        var parser: Parser = .{ .data = "rgb(1%,2,3)" };
        try testing.expectEqual(null, Color.parseIntPercent(&parser));
        try testing.expectEqual(.percent, parser.err.?.expected);
        try testing.expectEqual(8, parser.err.?.pos.start);
        try testing.expectEqual(8, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at pos 9: expected '%', found ','\n");
    }

    {
        // Error (inconsistent % usage 2)
        var parser: Parser = .{ .data = "rgb(1%,2%,3)" };
        try testing.expectEqual(null, Color.parseIntPercent(&parser));
        try testing.expectEqual(.percent, parser.err.?.expected);
        try testing.expectEqual(11, parser.err.?.pos.start);
        try testing.expectEqual(11, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at pos 12: expected '%', found ')'\n");
    }

    {
        // Error (inconsistent % usage 3)
        var parser: Parser = .{ .data = "rgb(1,2%,3)" };
        try testing.expectEqual(null, Color.parseIntPercent(&parser));
        try testing.expectEqual(.comma, parser.err.?.expected);
        try testing.expectEqual(7, parser.err.?.pos.start);
        try testing.expectEqual(7, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at pos 8: expected ',', found '%'\n");
    }
}

test "Color.parseName" {
    {
        // Basic
        try testing.expectEqual(
            Color.Value{ .r = 255, .g = 127, .b = 80 },
            Color.parseName("coral"),
        );
    }

    {
        // Missing
        try testing.expectEqual(null, Color.parseName("aaaaaa"));
    }
}

test "Path.parse" {
    {
        // Good, triangle
        var path = Path.init(
            testing.allocator,
            "M 100 101 L 300 100 L 200 300 z",
        );
        defer path.deinit();

        try path._parse();
        try testing.expectEqual(null, path.parser.err);
        try testing.expectEqual(4, path.nodes.len);
        try testing.expectEqual(false, path.nodes[0].move_to.relative);
        try testing.expectEqual(100, path.nodes[0].move_to.args[0].coordinates[0].number.value);
        try testing.expectEqual(101, path.nodes[0].move_to.args[0].coordinates[1].number.value);
        try testing.expectEqual(false, path.nodes[1].line_to.relative);
        try testing.expectEqual(300, path.nodes[1].line_to.args[0].coordinates[0].number.value);
        try testing.expectEqual(100, path.nodes[1].line_to.args[0].coordinates[1].number.value);
        try testing.expectEqual(false, path.nodes[2].line_to.relative);
        try testing.expectEqual(200, path.nodes[2].line_to.args[0].coordinates[0].number.value);
        try testing.expectEqual(300, path.nodes[2].line_to.args[0].coordinates[1].number.value);
        try testing.expect(path.nodes[3] == .close_path);
        try testing.expectEqual(0, path.nodes[0].move_to.pos.start);
        try testing.expectEqual(8, path.nodes[0].move_to.pos.end);
        try testing.expectEqual(10, path.nodes[1].line_to.pos.start);
        try testing.expectEqual(18, path.nodes[1].line_to.pos.end);
        try testing.expectEqual(20, path.nodes[2].line_to.pos.start);
        try testing.expectEqual(28, path.nodes[2].line_to.pos.end);
        try testing.expectEqual(30, path.nodes[3].close_path.pos.start);
        try testing.expectEqual(30, path.nodes[3].close_path.pos.end);
    }

    {
        // Good, all nodes
        //
        // Note that assertions here are terse just to ensure brevity of the
        // test.
        var path = Path.init(
            testing.allocator,
            \\M 1,1
            \\m 1,1
            \\Z
            \\z
            \\L 1,1
            \\l 1,1
            \\H 1
            \\h 1
            \\V 1
            \\v 1
            \\C 1,1 1,1 1,1
            \\c 1,1 1,1 1,1
            \\S 1,1 1,1
            \\s 1,1 1,1
            \\Q 1,1 1,1
            \\q 1,1 1,1
            \\T 1,1
            \\t 1,1
            \\A 1,1 11 0,1 1,1 
            \\a 1,1 11 0,1 1,1 
            ,
        );
        defer path.deinit();

        try path._parse();
        try testing.expectEqual(null, path.parser.err);
        try testing.expectEqual(20, path.nodes.len);
        try testing.expect(path.nodes[0] == .move_to);
        try testing.expect(path.nodes[1] == .move_to);
        try testing.expect(path.nodes[2] == .close_path);
        try testing.expect(path.nodes[3] == .close_path);
        try testing.expect(path.nodes[4] == .line_to);
        try testing.expect(path.nodes[5] == .line_to);
        try testing.expect(path.nodes[6] == .horizontal_line_to);
        try testing.expect(path.nodes[7] == .horizontal_line_to);
        try testing.expect(path.nodes[8] == .vertical_line_to);
        try testing.expect(path.nodes[9] == .vertical_line_to);
        try testing.expect(path.nodes[10] == .curve_to);
        try testing.expect(path.nodes[11] == .curve_to);
        try testing.expect(path.nodes[12] == .smooth_curve_to);
        try testing.expect(path.nodes[13] == .smooth_curve_to);
        try testing.expect(path.nodes[14] == .quadratic_bezier_curve_to);
        try testing.expect(path.nodes[15] == .quadratic_bezier_curve_to);
        try testing.expect(path.nodes[16] == .smooth_quadratic_bezier_curve_to);
        try testing.expect(path.nodes[17] == .smooth_quadratic_bezier_curve_to);
        try testing.expect(path.nodes[18] == .elliptical_arc);
        try testing.expect(path.nodes[19] == .elliptical_arc);
    }

    {
        // Bad, but parsed to last good node
        var path = Path.init(
            testing.allocator,
            "M 100 101 L 300 100 Lx",
        );
        defer path.deinit();

        try path._parse();
        try testing.expectEqual(2, path.nodes.len);
        try testing.expect(path.nodes[0] == .move_to);
        try testing.expect(path.nodes[1] == .line_to);
        try testing.expectEqual(.coordinate_pair, path.parser.err.?.expected);
        try testing.expectEqual(21, path.parser.err.?.pos.start);
        try testing.expectEqual(21, path.parser.err.?.pos.end);
        try testing.expectEqual(20, path.parser.pos);
        try testError(&path.parser, "at pos 22: expected coordinate pair, found 'x'\n");
    }

    {
        // Bad, but parsed to last good node (unknown command)
        var path = Path.init(
            testing.allocator,
            "M 100 101 L 300 100 x",
        );
        defer path.deinit();

        try path._parse();
        try testing.expectEqual(2, path.nodes.len);
        try testing.expect(path.nodes[0] == .move_to);
        try testing.expect(path.nodes[1] == .line_to);
        try testing.expectEqual(.drawto_command, path.parser.err.?.expected);
        try testing.expectEqual(20, path.parser.err.?.pos.start);
        try testing.expectEqual(20, path.parser.err.?.pos.end);
        try testing.expectEqual(20, path.parser.pos);
        try testError(&path.parser, "at pos 21: expected draw command [ACHLMQSTVZachlmqstvz], found 'x'\n");
    }

    {
        // Bad, must start with move_to
        var path = Path.init(
            testing.allocator,
            "L 100 101 L 300 100 z",
        );
        defer path.deinit();

        try path._parse();
        try testing.expectEqual(0, path.nodes.len);
        try testing.expectEqual(.M_or_m, path.parser.err.?.expected);
        try testing.expectEqual(0, path.parser.err.?.pos.start);
        try testing.expectEqual(0, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 1: expected 'M' or 'm', found 'L'\n");
    }
}

test "MoveTo" {
    {
        // Good, single, absolute
        var path = Path.init(
            testing.allocator,
            "M 10,11 Z",
        );
        defer path.deinit();

        const got = try Path.MoveTo.parse(&path);
        try testing.expectEqual(null, path.parser.err);
        try testing.expectEqual(false, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(6, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(6, got.?.pos.end);
        try testing.expectEqual(7, path.parser.pos);
    }

    {
        // Good, single, relative
        var path = Path.init(
            testing.allocator,
            "m 10,11 Z",
        );
        defer path.deinit();

        const got = try Path.MoveTo.parse(&path);
        try testing.expectEqual(null, path.parser.err);
        try testing.expectEqual(true, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(6, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(6, got.?.pos.end);
        try testing.expectEqual(7, path.parser.pos);
    }

    {
        // Good, multiple
        var path = Path.init(
            testing.allocator,
            "M 10,11 20,21 30,31 Z",
        );
        defer path.deinit();

        const got = try Path.MoveTo.parse(&path);
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
        try testing.expectEqual(19, path.parser.pos);
    }

    {
        // Bad, invalid command
        //
        // Note that we assert this on reading the production, but it should
        // never come up in real-world use.
        var path = Path.init(
            testing.allocator,
            "x 10,11",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.MoveTo.parse(&path));
        try testing.expectEqual(.M_or_m, path.parser.err.?.expected);
        try testing.expectEqual(0, path.parser.err.?.pos.start);
        try testing.expectEqual(0, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 1: expected 'M' or 'm', found 'x'\n");
    }

    {
        // Bad, incomplete arg
        var path = Path.init(
            testing.allocator,
            "M 25,",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.MoveTo.parse(&path));
        try testing.expectEqual(.coordinate_pair, path.parser.err.?.expected);
        try testing.expectEqual(2, path.parser.err.?.pos.start);
        try testing.expectEqual(4, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 3: expected coordinate pair, found '25,'\n");
    }
}

test "ClosePath" {
    {
        // Good
        var path = Path.init(
            testing.allocator,
            "Z z",
        );
        defer path.deinit();

        var got = try Path.ClosePath.parse(&path);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(0, got.?.pos.end);
        try testing.expectEqual(1, path.parser.pos);

        path.parser.pos += 1;
        got = try Path.ClosePath.parse(&path);
        try testing.expectEqual(2, got.?.pos.start);
        try testing.expectEqual(2, got.?.pos.end);
        try testing.expectEqual(3, path.parser.pos);
    }

    {
        // Bad, invalid command
        //
        // Note that we assert this on reading the production, but it should
        // never come up in real-world use.
        var path = Path.init(
            testing.allocator,
            "x",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.ClosePath.parse(&path));
        try testing.expectEqual(.Z_or_z, path.parser.err.?.expected);
        try testing.expectEqual(0, path.parser.err.?.pos.start);
        try testing.expectEqual(0, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 1: expected 'Z' or 'z', found 'x'\n");
    }
}

test "LineTo" {
    {
        // Good, single, absolute
        var path = Path.init(
            testing.allocator,
            "L 10,11 Z",
        );
        defer path.deinit();

        const got = try Path.LineTo.parse(&path);
        try testing.expectEqual(null, path.parser.err);
        try testing.expectEqual(false, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(6, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(6, got.?.pos.end);
        try testing.expectEqual(7, path.parser.pos);
    }

    {
        // Good, single, relative
        var path = Path.init(
            testing.allocator,
            "l 10,11 Z",
        );
        defer path.deinit();

        const got = try Path.LineTo.parse(&path);
        try testing.expectEqual(null, path.parser.err);
        try testing.expectEqual(true, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(6, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(6, got.?.pos.end);
        try testing.expectEqual(7, path.parser.pos);
    }

    {
        // Good, multiple
        var path = Path.init(
            testing.allocator,
            "L 10,11 20,21 30,31 Z",
        );
        defer path.deinit();

        const got = try Path.LineTo.parse(&path);
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
        try testing.expectEqual(19, path.parser.pos);
    }

    {
        // Bad, invalid command
        //
        // Note that we assert this on reading the production, but it should
        // never come up in real-world use.
        var path = Path.init(
            testing.allocator,
            "x 10,11",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.LineTo.parse(&path));
        try testing.expectEqual(.L_or_l, path.parser.err.?.expected);
        try testing.expectEqual(0, path.parser.err.?.pos.start);
        try testing.expectEqual(0, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 1: expected 'L' or 'l', found 'x'\n");
    }

    {
        // Bad, incomplete arg
        var path = Path.init(
            testing.allocator,
            "L 25,",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.LineTo.parse(&path));
        try testing.expectEqual(.coordinate_pair, path.parser.err.?.expected);
        try testing.expectEqual(2, path.parser.err.?.pos.start);
        try testing.expectEqual(4, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 3: expected coordinate pair, found '25,'\n");
    }
}

test "HorizontalLineTo" {
    {
        // Good, single, absolute
        var path = Path.init(
            testing.allocator,
            "H 10 Z",
        );
        defer path.deinit();

        const got = try Path.HorizontalLineTo.parse(&path);
        try testing.expectEqual(null, path.parser.err);
        try testing.expectEqual(false, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(3, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(3, got.?.pos.end);
        try testing.expectEqual(4, path.parser.pos);
    }

    {
        // Good, single, relative
        var path = Path.init(
            testing.allocator,
            "h 10 Z",
        );
        defer path.deinit();

        const got = try Path.HorizontalLineTo.parse(&path);
        try testing.expectEqual(null, path.parser.err);
        try testing.expectEqual(true, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(3, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(3, got.?.pos.end);
        try testing.expectEqual(4, path.parser.pos);
    }

    {
        // Good, multiple
        var path = Path.init(
            testing.allocator,
            "H 10 11 12 Z",
        );
        defer path.deinit();

        const got = try Path.HorizontalLineTo.parse(&path);
        try testing.expectEqual(null, path.parser.err);
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
        try testing.expectEqual(10, path.parser.pos);
    }

    {
        // Bad, invalid command
        //
        // Note that we assert this on reading the production, but it should
        // never come up in real-world use.
        var path = Path.init(
            testing.allocator,
            "x 10",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.HorizontalLineTo.parse(&path));
        try testing.expectEqual(.H_or_h, path.parser.err.?.expected);
        try testing.expectEqual(0, path.parser.err.?.pos.start);
        try testing.expectEqual(0, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 1: expected 'H' or 'h', found 'x'\n");
    }

    {
        // Bad, incomplete arg
        var path = Path.init(
            testing.allocator,
            "H ,",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.HorizontalLineTo.parse(&path));
        try testing.expectEqual(.number, path.parser.err.?.expected);
        try testing.expectEqual(2, path.parser.err.?.pos.start);
        try testing.expectEqual(2, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 3: expected number, found ','\n");
    }
}

test "VerticalLineTo" {
    {
        // Good, single, absolute
        var path = Path.init(
            testing.allocator,
            "V 10 Z",
        );
        defer path.deinit();

        const got = try Path.VerticalLineTo.parse(&path);
        try testing.expectEqual(null, path.parser.err);
        try testing.expectEqual(false, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(3, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(3, got.?.pos.end);
        try testing.expectEqual(4, path.parser.pos);
    }

    {
        // Good, single, relative
        var path = Path.init(
            testing.allocator,
            "v 10 Z",
        );
        defer path.deinit();

        const got = try Path.VerticalLineTo.parse(&path);
        try testing.expectEqual(null, path.parser.err);
        try testing.expectEqual(true, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(3, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(3, got.?.pos.end);
        try testing.expectEqual(4, path.parser.pos);
    }

    {
        // Good, multiple
        var path = Path.init(
            testing.allocator,
            "V 10 11 12 Z",
        );
        defer path.deinit();

        const got = try Path.VerticalLineTo.parse(&path);
        try testing.expectEqual(null, path.parser.err);
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
        try testing.expectEqual(10, path.parser.pos);
    }

    {
        // Bad, invalid command
        //
        // Note that we assert this on reading the production, but it should
        // never come up in real-world use.
        var path = Path.init(
            testing.allocator,
            "x 10",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.VerticalLineTo.parse(&path));
        try testing.expectEqual(.V_or_v, path.parser.err.?.expected);
        try testing.expectEqual(0, path.parser.err.?.pos.start);
        try testing.expectEqual(0, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 1: expected 'V' or 'v', found 'x'\n");
    }

    {
        // Bad, incomplete arg
        var path = Path.init(
            testing.allocator,
            "V ,",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.VerticalLineTo.parse(&path));
        try testing.expectEqual(.number, path.parser.err.?.expected);
        try testing.expectEqual(2, path.parser.err.?.pos.start);
        try testing.expectEqual(2, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 3: expected number, found ','\n");
    }
}

test "CurveTo" {
    {
        // Good, single, absolute
        var path = Path.init(
            testing.allocator,
            "C 10,11 20,21 30,31",
        );
        defer path.deinit();

        const got = try Path.CurveTo.parse(&path);
        try testing.expectEqual(null, path.parser.err);
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
        try testing.expectEqual(19, path.parser.pos);
    }

    {
        // Good, single, relative
        var path = Path.init(
            testing.allocator,
            "c 10,11 20,21 30,31 Z",
        );
        defer path.deinit();

        const got = try Path.CurveTo.parse(&path);
        try testing.expectEqual(null, path.parser.err);
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
        try testing.expectEqual(19, path.parser.pos);
    }

    {
        // Good, multiple
        var path = Path.init(
            testing.allocator,
            \\C 10,11 20,21 30,31
            \\40,41 50,51 60,61
            \\70,71 80,81 90,91 Z
            ,
        );
        defer path.deinit();

        const got = try Path.CurveTo.parse(&path);
        try testing.expectEqual(null, path.parser.err);
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
        try testing.expectEqual(55, path.parser.pos);
    }

    {
        // Bad, invalid command
        //
        // Note that we assert this on reading the production, but it should
        // never come up in real-world use.
        var path = Path.init(
            testing.allocator,
            "x 10,11 20,21 30,31",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.CurveTo.parse(&path));
        try testing.expectEqual(.C_or_c, path.parser.err.?.expected);
        try testing.expectEqual(0, path.parser.err.?.pos.start);
        try testing.expectEqual(0, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 1: expected 'C' or 'c', found 'x'\n");
    }

    {
        // Bad, incomplete arg
        var path = Path.init(
            testing.allocator,
            "C 10,11 20,Z",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.CurveTo.parse(&path));
        try testing.expectEqual(.coordinate_pair, path.parser.err.?.expected);
        try testing.expectEqual(8, path.parser.err.?.pos.start);
        try testing.expectEqual(11, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 9: expected coordinate pair, found '20,Z'\n");
    }
}

test "SmoothCurveTo" {
    {
        // Good, single, absolute
        var path = Path.init(
            testing.allocator,
            "S 10,11 20,21",
        );
        defer path.deinit();

        const got = try Path.SmoothCurveTo.parse(&path);
        try testing.expectEqual(null, path.parser.err);
        try testing.expectEqual(false, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].p2.coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].p2.coordinates[1].number.value);
        try testing.expectEqual(20, got.?.args[0].end.coordinates[0].number.value);
        try testing.expectEqual(21, got.?.args[0].end.coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(12, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(12, got.?.pos.end);
        try testing.expectEqual(13, path.parser.pos);
    }

    {
        // Good, single, relative
        var path = Path.init(
            testing.allocator,
            "s 10,11 20,21 Z",
        );
        defer path.deinit();

        const got = try Path.SmoothCurveTo.parse(&path);
        try testing.expectEqual(null, path.parser.err);
        try testing.expectEqual(true, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].p2.coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].p2.coordinates[1].number.value);
        try testing.expectEqual(20, got.?.args[0].end.coordinates[0].number.value);
        try testing.expectEqual(21, got.?.args[0].end.coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(12, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(12, got.?.pos.end);
        try testing.expectEqual(13, path.parser.pos);
    }

    {
        // Good, multiple
        var path = Path.init(
            testing.allocator,
            \\S 10,11 20,21
            \\30,31 40,41
            \\50,51 60,61 Z
            ,
        );
        defer path.deinit();

        const got = try Path.SmoothCurveTo.parse(&path);
        try testing.expectEqual(null, path.parser.err);
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
        try testing.expectEqual(37, path.parser.pos);
    }

    {
        // Bad, invalid command
        //
        // Note that we assert this on reading the production, but it should
        // never come up in real-world use.
        var path = Path.init(
            testing.allocator,
            "x 10,11 20,21",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.SmoothCurveTo.parse(&path));
        try testing.expectEqual(.S_or_s, path.parser.err.?.expected);
        try testing.expectEqual(0, path.parser.err.?.pos.start);
        try testing.expectEqual(0, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 1: expected 'S' or 's', found 'x'\n");
    }

    {
        // Bad, incomplete arg
        var path = Path.init(
            testing.allocator,
            "S 10,11 20,Z",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.SmoothCurveTo.parse(&path));
        try testing.expectEqual(.coordinate_pair, path.parser.err.?.expected);
        try testing.expectEqual(8, path.parser.err.?.pos.start);
        try testing.expectEqual(11, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 9: expected coordinate pair, found '20,Z'\n");
    }
}

test "QuadraticBezierCurveTo" {
    {
        // Good, single, absolute
        var path = Path.init(
            testing.allocator,
            "Q 10,11 20,21",
        );
        defer path.deinit();

        const got = try Path.QuadraticBezierCurveTo.parse(&path);
        try testing.expectEqual(null, path.parser.err);
        try testing.expectEqual(false, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].p1.coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].p1.coordinates[1].number.value);
        try testing.expectEqual(20, got.?.args[0].end.coordinates[0].number.value);
        try testing.expectEqual(21, got.?.args[0].end.coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(12, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(12, got.?.pos.end);
        try testing.expectEqual(13, path.parser.pos);
    }

    {
        // Good, single, relative
        var path = Path.init(
            testing.allocator,
            "q 10,11 20,21 Z",
        );
        defer path.deinit();

        const got = try Path.QuadraticBezierCurveTo.parse(&path);
        try testing.expectEqual(null, path.parser.err);
        try testing.expectEqual(true, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].p1.coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].p1.coordinates[1].number.value);
        try testing.expectEqual(20, got.?.args[0].end.coordinates[0].number.value);
        try testing.expectEqual(21, got.?.args[0].end.coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(12, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(12, got.?.pos.end);
        try testing.expectEqual(13, path.parser.pos);
    }

    {
        // Good, multiple
        var path = Path.init(
            testing.allocator,
            \\Q 10,11 20,21
            \\30,31 40,41
            \\50,51 60,61 Z
            ,
        );
        defer path.deinit();

        const got = try Path.QuadraticBezierCurveTo.parse(&path);
        try testing.expectEqual(null, path.parser.err);
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
        try testing.expectEqual(37, path.parser.pos);
    }

    {
        // Bad, invalid command
        //
        // Note that we assert this on reading the production, but it should
        // never come up in real-world use.
        var path = Path.init(
            testing.allocator,
            "x 10,11 20,21",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.QuadraticBezierCurveTo.parse(&path));
        try testing.expectEqual(.Q_or_q, path.parser.err.?.expected);
        try testing.expectEqual(0, path.parser.err.?.pos.start);
        try testing.expectEqual(0, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 1: expected 'Q' or 'q', found 'x'\n");
    }

    {
        // Bad, incomplete arg
        var path = Path.init(
            testing.allocator,
            "Q 10,11 20,Z",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.QuadraticBezierCurveTo.parse(&path));
        try testing.expectEqual(.coordinate_pair, path.parser.err.?.expected);
        try testing.expectEqual(8, path.parser.err.?.pos.start);
        try testing.expectEqual(11, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 9: expected coordinate pair, found '20,Z'\n");
    }
}

test "SmoothQuadraticBezierCurveTo" {
    {
        // Good, single, absolute
        var path = Path.init(
            testing.allocator,
            "T 10,11 Z",
        );
        defer path.deinit();

        const got = try Path.SmoothQuadraticBezierCurveTo.parse(&path);
        try testing.expectEqual(null, path.parser.err);
        try testing.expectEqual(false, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(6, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(6, got.?.pos.end);
        try testing.expectEqual(7, path.parser.pos);
    }

    {
        // Good, single, relative
        var path = Path.init(
            testing.allocator,
            "t 10,11 Z",
        );
        defer path.deinit();

        const got = try Path.SmoothQuadraticBezierCurveTo.parse(&path);
        try testing.expectEqual(null, path.parser.err);
        try testing.expectEqual(true, got.?.relative);
        try testing.expectEqual(10, got.?.args[0].coordinates[0].number.value);
        try testing.expectEqual(11, got.?.args[0].coordinates[1].number.value);
        try testing.expectEqual(2, got.?.args[0].pos.start);
        try testing.expectEqual(6, got.?.args[0].pos.end);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(6, got.?.pos.end);
        try testing.expectEqual(7, path.parser.pos);
    }

    {
        // Good, multiple
        var path = Path.init(
            testing.allocator,
            "T 10,11 20,21 30,31 Z",
        );
        defer path.deinit();

        const got = try Path.SmoothQuadraticBezierCurveTo.parse(&path);
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
        try testing.expectEqual(19, path.parser.pos);
    }

    {
        // Bad, invalid command
        //
        // Note that we assert this on reading the production, but it should
        // never come up in real-world use.
        var path = Path.init(
            testing.allocator,
            "x 10,11",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.SmoothQuadraticBezierCurveTo.parse(&path));
        try testing.expectEqual(.T_or_t, path.parser.err.?.expected);
        try testing.expectEqual(0, path.parser.err.?.pos.start);
        try testing.expectEqual(0, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 1: expected 'T' or 't', found 'x'\n");
    }

    {
        // Bad, incomplete arg
        var path = Path.init(
            testing.allocator,
            "T 25,",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.SmoothQuadraticBezierCurveTo.parse(&path));
        try testing.expectEqual(.coordinate_pair, path.parser.err.?.expected);
        try testing.expectEqual(2, path.parser.err.?.pos.start);
        try testing.expectEqual(4, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 3: expected coordinate pair, found '25,'\n");
    }
}

test "EllipticalArc" {
    {
        // Good, single, absolute
        var path = Path.init(
            testing.allocator,
            "A 25,26 -30 0,1 50,-25",
        );
        defer path.deinit();

        const got = try Path.EllipticalArc.parse(&path);
        try testing.expectEqual(null, path.parser.err);
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
        try testing.expectEqual(22, path.parser.pos);
    }

    {
        // Good, single, relative
        var path = Path.init(
            testing.allocator,
            "a 25,26 -30 0,1 50,-25 Z",
        );
        defer path.deinit();

        const got = try Path.EllipticalArc.parse(&path);
        try testing.expectEqual(null, path.parser.err);
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
        try testing.expectEqual(22, path.parser.pos);
    }

    {
        // Good, multiple
        var path = Path.init(
            testing.allocator,
            \\A 25,26 -30 0,1 50,-25
            \\26,51 -29 1,0 49,-26
            \\27,52 -28 0,1 48,-27 Z
            ,
        );
        defer path.deinit();

        const got = try Path.EllipticalArc.parse(&path);
        try testing.expectEqual(null, path.parser.err);
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
        try testing.expectEqual(64, path.parser.pos);
    }

    {
        // Bad, invalid command
        //
        // Note that we assert this on reading the production, but it should
        // never come up in real-world use.
        var path = Path.init(
            testing.allocator,
            "x 25,26 -30 0,1 50,-25",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.EllipticalArc.parse(&path));
        try testing.expectEqual(.A_or_a, path.parser.err.?.expected);
        try testing.expectEqual(0, path.parser.err.?.pos.start);
        try testing.expectEqual(0, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 1: expected 'A' or 'a', found 'x'\n");
    }

    {
        // Bad, incomplete arg
        var path = Path.init(
            testing.allocator,
            "A 25,26 -30 Z",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.EllipticalArc.parse(&path));
        try testing.expectEqual(.flag, path.parser.err.?.expected);
        try testing.expectEqual(12, path.parser.err.?.pos.start);
        try testing.expectEqual(12, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 13: expected '0' or '1', found 'Z'\n");
    }
}

test "EllipticalArcArgument" {
    {
        // Basic
        var path = Path.init(
            testing.allocator,
            "25,26 -30 0,1 50,-25",
        );
        defer path.deinit();

        const got = Path.EllipticalArcArgument.parse(&path);
        try testing.expectEqual(null, path.parser.err);
        try testing.expectEqual(25, got.?.rx.value);
        try testing.expectEqual(26, got.?.ry.value);
        try testing.expectEqual(-30, got.?.x_axis_rotation.value);
        try testing.expectEqual(false, got.?.large_arc_flag.value);
        try testing.expectEqual(true, got.?.sweep_flag.value);
        try testing.expectEqual(50, got.?.point.coordinates[0].number.value);
        try testing.expectEqual(-25, got.?.point.coordinates[1].number.value);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(19, got.?.pos.end);
        try testing.expectEqual(20, path.parser.pos);
    }

    {
        // Bad, negative rx
        var path = Path.init(
            testing.allocator,
            "-25,26 -30 0,1 50,-25",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.EllipticalArcArgument.parse(&path));
        try testing.expectEqual(.nonnegative_number, path.parser.err.?.expected);
        try testing.expectEqual(0, path.parser.err.?.pos.start);
        try testing.expectEqual(2, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 1: expected non-negative number, found '-25'\n");
    }

    {
        // Bad, negative ry
        var path = Path.init(
            testing.allocator,
            "25,-26 -30 0,1 50,-25",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.EllipticalArcArgument.parse(&path));
        try testing.expectEqual(.nonnegative_number, path.parser.err.?.expected);
        try testing.expectEqual(3, path.parser.err.?.pos.start);
        try testing.expectEqual(5, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 4: expected non-negative number, found '-26'\n");
    }

    {
        // Bad, non-number rotation
        var path = Path.init(
            testing.allocator,
            "25,26 aa 0,1 50,-25",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.EllipticalArcArgument.parse(&path));
        try testing.expectEqual(.number, path.parser.err.?.expected);
        try testing.expectEqual(6, path.parser.err.?.pos.start);
        try testing.expectEqual(6, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 7: expected number, found 'a'\n");
    }

    {
        // Bad, non-flag large-arc-flag
        var path = Path.init(
            testing.allocator,
            "25,26 -30 2,1 50,-25",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.EllipticalArcArgument.parse(&path));
        try testing.expectEqual(.flag, path.parser.err.?.expected);
        try testing.expectEqual(10, path.parser.err.?.pos.start);
        try testing.expectEqual(10, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 11: expected '0' or '1', found '2'\n");
    }

    {
        // Bad, non-flag sweep-flag
        var path = Path.init(
            testing.allocator,
            "25,26 -30 0,2 50,-25",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.EllipticalArcArgument.parse(&path));
        try testing.expectEqual(.flag, path.parser.err.?.expected);
        try testing.expectEqual(12, path.parser.err.?.pos.start);
        try testing.expectEqual(12, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 13: expected '0' or '1', found '2'\n");
    }

    {
        // Bad, non-number x
        var path = Path.init(
            testing.allocator,
            "25,26 -30 0,1 a,-25",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.EllipticalArcArgument.parse(&path));
        try testing.expectEqual(.coordinate_pair, path.parser.err.?.expected);
        try testing.expectEqual(14, path.parser.err.?.pos.start);
        try testing.expectEqual(14, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 15: expected coordinate pair, found 'a'\n");
    }

    {
        // Bad, non-number y
        var path = Path.init(
            testing.allocator,
            "25,26 -30 0,1 50,a",
        );
        defer path.deinit();

        try testing.expectEqual(null, Path.EllipticalArcArgument.parse(&path));
        try testing.expectEqual(.coordinate_pair, path.parser.err.?.expected);
        try testing.expectEqual(14, path.parser.err.?.pos.start);
        try testing.expectEqual(17, path.parser.err.?.pos.end);
        try testing.expectEqual(0, path.parser.pos);
        try testError(&path.parser, "at pos 15: expected coordinate pair, found '50,a'\n");
    }
}

test "CoordinatePair" {
    {
        // Basic
        var parser: Parser = .{ .data = "123 456.789 123,456.789 123-456" };

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
        try testError(&parser, "at pos 31: expected coordinate pair, found end of data\n");
    }

    {
        // Bad, second arg
        var parser: Parser = .{ .data = "123,a" };

        try testing.expectEqual(null, CoordinatePair.parse(&parser));
        try testing.expectEqual(.coordinate_pair, parser.err.?.expected);
        try testing.expectEqual(0, parser.err.?.pos.start);
        try testing.expectEqual(4, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at pos 1: expected coordinate pair, found '123,a'\n");
    }

    {
        // Bad, no second arg, end of path data
        var parser: Parser = .{ .data = "123," };

        try testing.expectEqual(null, CoordinatePair.parse(&parser));
        try testing.expectEqual(.coordinate_pair, parser.err.?.expected);
        try testing.expectEqual(0, parser.err.?.pos.start);
        try testing.expectEqual(3, parser.err.?.pos.end);
        try testing.expectEqual(0, parser.pos);
        try testError(&parser, "at pos 1: expected coordinate pair, found '123,'\n");
    }
}

test "Coordinate" {
    {
        // Basic
        var parser: Parser = .{ .data = "123 456.789" };

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
        var parser: Parser = .{ .data = "0 1 2" };

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
        var parser: Parser = .{ .data = "1 2 0 123 45a6 789 -123 123-123 123.456 +123+123" };

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
        var parser: Parser = .{ .data = "10e1 10e+1 10e-1 10e10 10ee 10e.1 -.1e1 0.01e+2" };

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

test "Integer" {
    {
        // Basic
        var parser: Parser = .{ .data = "1 2 0 123 45a6 789 -123 123-123 123.456 +123+123" };

        var got = Integer.parse(&parser);
        try testing.expectEqual(1, got.?.value);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(0, got.?.pos.end);
        try testing.expectEqual(1, parser.pos);

        parser.pos += 1;
        got = Integer.parse(&parser);
        try testing.expectEqual(2, got.?.value);
        try testing.expectEqual(2, got.?.pos.start);
        try testing.expectEqual(2, got.?.pos.end);
        try testing.expectEqual(3, parser.pos);

        parser.pos += 1;
        got = Integer.parse(&parser);
        try testing.expectEqual(0, got.?.value);
        try testing.expectEqual(4, got.?.pos.start);
        try testing.expectEqual(4, got.?.pos.end);
        try testing.expectEqual(5, parser.pos);

        parser.pos += 1;
        got = Integer.parse(&parser);
        try testing.expectEqual(123, got.?.value);
        try testing.expectEqual(6, got.?.pos.start);
        try testing.expectEqual(8, got.?.pos.end);
        try testing.expectEqual(9, parser.pos);

        parser.pos += 1;
        got = Integer.parse(&parser);
        try testing.expectEqual(45, got.?.value);
        try testing.expectEqual(10, got.?.pos.start);
        try testing.expectEqual(11, got.?.pos.end);
        try testing.expectEqual(12, parser.pos);
        try testing.expectEqual(null, Number.parse(&parser));

        parser.pos += 1;
        got = Integer.parse(&parser);
        try testing.expectEqual(6, got.?.value);
        try testing.expectEqual(13, got.?.pos.start);
        try testing.expectEqual(13, got.?.pos.end);
        try testing.expectEqual(14, parser.pos);

        parser.pos += 1;
        got = Integer.parse(&parser);
        try testing.expectEqual(789, got.?.value);
        try testing.expectEqual(15, got.?.pos.start);
        try testing.expectEqual(17, got.?.pos.end);
        try testing.expectEqual(18, parser.pos);

        parser.pos += 1;
        got = Integer.parse(&parser);
        try testing.expectEqual(-123, got.?.value);
        try testing.expectEqual(19, got.?.pos.start);
        try testing.expectEqual(22, got.?.pos.end);
        try testing.expectEqual(23, parser.pos);

        parser.pos += 1;
        got = Integer.parse(&parser);
        try testing.expectEqual(123, got.?.value);
        try testing.expectEqual(24, got.?.pos.start);
        try testing.expectEqual(26, got.?.pos.end);
        try testing.expectEqual(27, parser.pos);

        got = Integer.parse(&parser);
        try testing.expectEqual(-123, got.?.value);
        try testing.expectEqual(27, got.?.pos.start);
        try testing.expectEqual(30, got.?.pos.end);
        try testing.expectEqual(31, parser.pos);

        parser.pos += 1;
        got = Integer.parse(&parser);
        try testing.expectEqual(123, got.?.value);
        try testing.expectEqual(32, got.?.pos.start);
        try testing.expectEqual(34, got.?.pos.end);
        try testing.expectEqual(35, parser.pos);

        parser.pos += 1;
        got = Integer.parse(&parser);
        try testing.expectEqual(456, got.?.value);
        try testing.expectEqual(36, got.?.pos.start);
        try testing.expectEqual(38, got.?.pos.end);
        try testing.expectEqual(39, parser.pos);

        parser.pos += 1;
        got = Integer.parse(&parser);
        try testing.expectEqual(123, got.?.value);
        try testing.expectEqual(40, got.?.pos.start);
        try testing.expectEqual(43, got.?.pos.end);
        try testing.expectEqual(44, parser.pos);

        got = Integer.parse(&parser);
        try testing.expectEqual(123, got.?.value);
        try testing.expectEqual(44, got.?.pos.start);
        try testing.expectEqual(47, got.?.pos.end);
        try testing.expectEqual(48, parser.pos);

        try testing.expectEqual(null, Integer.parse(&parser));
    }

    {
        // Hex
        var parser: Parser = .{ .data = "1 a A 10 0a bc -F" };

        var got = Integer.parseHex(&parser, 2);
        try testing.expectEqual(1, got.?.value);
        try testing.expectEqual(0, got.?.pos.start);
        try testing.expectEqual(0, got.?.pos.end);
        try testing.expectEqual(1, parser.pos);

        parser.pos += 1;
        got = Integer.parseHex(&parser, 2);
        try testing.expectEqual(10, got.?.value);
        try testing.expectEqual(2, got.?.pos.start);
        try testing.expectEqual(2, got.?.pos.end);
        try testing.expectEqual(3, parser.pos);

        parser.pos += 1;
        got = Integer.parseHex(&parser, 2);
        try testing.expectEqual(10, got.?.value);
        try testing.expectEqual(4, got.?.pos.start);
        try testing.expectEqual(4, got.?.pos.end);
        try testing.expectEqual(5, parser.pos);

        parser.pos += 1;
        got = Integer.parseHex(&parser, 2);
        try testing.expectEqual(16, got.?.value);
        try testing.expectEqual(6, got.?.pos.start);
        try testing.expectEqual(7, got.?.pos.end);
        try testing.expectEqual(8, parser.pos);

        parser.pos += 1;
        got = Integer.parseHex(&parser, 2);
        try testing.expectEqual(10, got.?.value);
        try testing.expectEqual(9, got.?.pos.start);
        try testing.expectEqual(10, got.?.pos.end);
        try testing.expectEqual(11, parser.pos);

        parser.pos += 1;
        got = Integer.parseHex(&parser, 1);
        try testing.expectEqual(11, got.?.value);
        try testing.expectEqual(12, got.?.pos.start);
        try testing.expectEqual(12, got.?.pos.end);
        try testing.expectEqual(13, parser.pos);

        got = Integer.parseHex(&parser, 1);
        try testing.expectEqual(12, got.?.value);
        try testing.expectEqual(13, got.?.pos.start);
        try testing.expectEqual(13, got.?.pos.end);
        try testing.expectEqual(14, parser.pos);

        parser.pos += 1;
        try testing.expectEqual(null, Integer.parseHex(&parser, 2));
        parser.pos += 1;
        got = Integer.parseHex(&parser, 2);
        try testing.expectEqual(15, got.?.value);
        try testing.expectEqual(16, got.?.pos.start);
        try testing.expectEqual(16, got.?.pos.end);
        try testing.expectEqual(17, parser.pos);

        try testing.expectEqual(null, Integer.parseHex(&parser, 99999));
    }
}

test "consumeWhitespace" {
    {
        var parser: Parser = .{ .data = "   a  " };

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
        var parser: Parser = .{ .data = "   ,  a  a  ,," };

        try testing.expectEqual(true, parser.consumeCommaWhitespace());
        try testing.expectEqual(6, parser.pos);
        try testing.expectEqual(false, parser.consumeCommaWhitespace());
        try testing.expectEqual(6, parser.pos);

        parser.pos += 1;
        try testing.expectEqual(false, parser.consumeCommaWhitespace());
        try testing.expectEqual(9, parser.pos);
        try testing.expectEqual(false, parser.consumeCommaWhitespace());
        try testing.expectEqual(9, parser.pos);

        parser.pos += 1;
        try testing.expectEqual(true, parser.consumeCommaWhitespace());
        try testing.expectEqual(13, parser.pos);
        try testing.expectEqual(true, parser.consumeCommaWhitespace());
        try testing.expectEqual(14, parser.pos);
    }
}

test "comsumePercent" {
    {
        var parser: Parser = .{ .data = "%,%" };

        try testing.expectEqual(true, parser.consumePercent());
        try testing.expectEqual(1, parser.pos);
        try testing.expectEqual(false, parser.consumePercent());
        try testing.expectEqual(1, parser.pos);

        parser.pos += 1;
        try testing.expectEqual(true, parser.consumePercent());
        try testing.expectEqual(3, parser.pos);
        try testing.expectEqual(false, parser.consumePercent());
        try testing.expectEqual(3, parser.pos);
    }
}

test "comsumeRParen" {
    {
        var parser: Parser = .{ .data = ")()" };

        try testing.expectEqual(true, parser.consumeRParen());
        try testing.expectEqual(1, parser.pos);
        try testing.expectEqual(false, parser.consumeRParen());
        try testing.expectEqual(1, parser.pos);

        parser.pos += 1;
        try testing.expectEqual(true, parser.consumeRParen());
        try testing.expectEqual(3, parser.pos);
        try testing.expectEqual(false, parser.consumeRParen());
        try testing.expectEqual(3, parser.pos);
    }
}

/// For testing only.
fn testError(p: *Parser, expected: [:0]const u8) !void {
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
        var parser: Parser = .{
            .data = "abc def ghi",
            .err = .{
                .expected = .coordinate_pair,
                .pos = .{
                    .start = 8,
                    .end = 10,
                },
            },
        };

        try testError(&parser, "at pos 9: expected coordinate pair, found 'ghi'\n");
    }
}

test "allocPrintErr" {
    {
        // Basic
        var parser: Parser = .{
            .data = "abc def ghi",
            .err = .{
                .expected = .coordinate_pair,
                .pos = .{
                    .start = 8,
                    .end = 10,
                },
            },
        };

        const got = try parser.allocPrintErr(testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, "at pos 9: expected coordinate pair, found 'ghi'", got);
    }

    {
        // End of data
        var parser: Parser = .{
            .data = "abc def ghi",
            .err = .{
                .expected = .coordinate_pair,
                .pos = .{
                    .start = 11,
                    .end = 11,
                },
            },
        };

        const got = try parser.allocPrintErr(testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, "at pos 11: expected coordinate pair, found end of data", got);
    }

    {
        // No error
        var parser: Parser = .{
            .data = "abc def ghi",
        };

        const got = try parser.allocPrintErr(testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, "", got);
    }
}
