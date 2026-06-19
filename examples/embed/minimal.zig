const std = @import("std");
const scoot = @import("scoot");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    const rt = try scoot.start(arena, init.io, .{
        .env = init.environ_map,
    });
    defer scoot.stop(rt);

    const reply = try scoot.run(rt, "Return a short greeting.");

    var buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    try stdout.interface.print("{s}\n", .{reply});
    try stdout.interface.flush();
}
