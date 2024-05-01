# zig-svg

zig-svg provides abstractions for SVG paths and a parser.

Note that this library only parses path data. We don't abstract all of SVG as
generally how you handle SVG is up to the renderer. Check out
(zig-xml)[https://github.com/nektro/zig-xml] for parsing the SVG XML itself.

## Parsing

To parse an SVG path, run `Path.parse`. This function takes an allocator and a
[]u8 with the path data in it.

After this is done, your parsed nodes will be available in the `nodes` attribute.

```zig
const Path = @import("svg").Path;
var path = try Path.parse(alloc, data);
defer path.deinit();
for (path.nodes) |n| {
  ...
}
```

## Errors

Only errors in allocation are reported as errors. All other errors are
non-fatal and are reported in the `err` attribute instead. In this case, as per
the [spec](https://www.w3.org/TR/SVG11/implnote.html#ErrorProcessing), all
valid path nodes are parsed and returned so that you can process up to the
error.

```zig
const io = @import("std").io;
const log = @import("std").log;
const Path = @import("svg").Path;
var path = try Path.parse(alloc, data);
defer path.deinit();
if (path.err) |err| {
    const errWriter = io.getStdErr();
    buf.format(errWriter, "error processing SVG: ");
    try path.fmtErr();
}

for (path.nodes) |n| {
  ...
}
```

## License

This project is licensed MPL 2.0. See LICENSE for a copy of the MPL.
