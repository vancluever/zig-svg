// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

pub const Path = @import("Path.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
