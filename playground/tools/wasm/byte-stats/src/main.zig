// byte-stats: a deterministic, compute-only Scoot Wasm tool.
//
// It reads the raw JSON payload Scoot writes to stdin and emits one JSON object
// with byte/line counts and a stable additive checksum. Determinism is the
// point: the agent can compute the same numbers independently and verify the
// tool round-trip, which makes it a good wasm_tool evaluation target.
//
// No std, no allocator, no ambient authority: only stdin (fd 0), stdout (fd 1),
// and proc_exit are used, all inside the minimal WASI preview1 subset that
// `scoot-wasm wasi` exposes.

const Iovec = extern struct {
    buf: [*]u8,
    buf_len: usize,
};

const Ciovec = extern struct {
    buf: [*]const u8,
    buf_len: usize,
};

extern "wasi_snapshot_preview1" fn fd_read(fd: u32, iovs: [*]const Iovec, iovs_len: usize, nread: *usize) u16;
extern "wasi_snapshot_preview1" fn fd_write(fd: u32, iovs: [*]const Ciovec, iovs_len: usize, nwritten: *usize) u16;
extern "wasi_snapshot_preview1" fn proc_exit(code: u32) noreturn;

var input_buf: [64 * 1024]u8 = undefined;
var output_buf: [256]u8 = undefined;

export fn _start() void {
    const len = readAllStdin();

    var bytes: usize = 0;
    var lines: usize = 0;
    var checksum: u32 = 0;
    for (input_buf[0..len]) |b| {
        bytes += 1;
        if (b == '\n') lines += 1;
        // Stable additive rolling checksum, kept inside u32 on purpose.
        checksum = (checksum +% (@as(u32, b) +% 1)) & 0x00ff_ffff;
    }
    // Count the final partial line when input does not end in a newline.
    if (len != 0 and input_buf[len - 1] != '\n') lines += 1;

    var out = FixedWriter{ .buf = &output_buf };
    out.write("{\"bytes\":");
    out.writeUsize(bytes);
    out.write(",\"lines\":");
    out.writeUsize(lines);
    out.write(",\"checksum\":");
    out.writeUsize(checksum);
    out.write("}\n");

    writeAll(1, out.slice());
    proc_exit(0);
}

fn readAllStdin() usize {
    var total: usize = 0;
    while (total < input_buf.len) {
        const iov = Iovec{
            .buf = input_buf[total..].ptr,
            .buf_len = input_buf.len - total,
        };
        const iovs = [_]Iovec{iov};
        var nread: usize = 0;
        const errno = fd_read(0, iovs[0..].ptr, iovs.len, &nread);
        if (errno != 0) proc_exit(2);
        if (nread == 0) break;
        total += nread;
    }
    return total;
}

fn writeAll(fd: u32, data: []const u8) void {
    var offset: usize = 0;
    while (offset < data.len) {
        const iov = Ciovec{
            .buf = data[offset..].ptr,
            .buf_len = data.len - offset,
        };
        const iovs = [_]Ciovec{iov};
        var written: usize = 0;
        const errno = fd_write(fd, iovs[0..].ptr, iovs.len, &written);
        if (errno != 0 or written == 0) proc_exit(3);
        offset += written;
    }
}

const FixedWriter = struct {
    buf: *[256]u8,
    len: usize = 0,

    fn write(self: *FixedWriter, bytes: []const u8) void {
        for (bytes) |b| self.writeByte(b);
    }

    fn writeUsize(self: *FixedWriter, value: usize) void {
        var tmp: [20]u8 = undefined;
        var n = value;
        var l: usize = 0;
        while (true) {
            tmp[l] = '0' + @as(u8, @intCast(n % 10));
            l += 1;
            n /= 10;
            if (n == 0) break;
        }
        while (l > 0) {
            l -= 1;
            self.writeByte(tmp[l]);
        }
    }

    fn writeByte(self: *FixedWriter, b: u8) void {
        if (self.len >= self.buf.len) proc_exit(4);
        self.buf[self.len] = b;
        self.len += 1;
    }

    fn slice(self: *const FixedWriter) []const u8 {
        return self.buf[0..self.len];
    }
};
