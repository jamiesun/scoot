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
    const input_len = readAllStdin();
    const input = input_buf[0..input_len];
    const count = findJsonNumber(input, "\"elided_count\"");
    const bytes = findJsonNumber(input, "\"elided_bytes\"");

    var out = FixedWriter{ .buf = &output_buf };
    out.write("{\"marker\":\"wasm example compressed ");
    out.writeUsize(count);
    out.write(" messages / ");
    out.writeUsize(bytes);
    out.write(" bytes\"}\n");

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

fn writeAll(fd: u32, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const iov = Ciovec{
            .buf = bytes[offset..].ptr,
            .buf_len = bytes.len - offset,
        };
        const iovs = [_]Ciovec{iov};
        var written: usize = 0;
        const errno = fd_write(fd, iovs[0..].ptr, iovs.len, &written);
        if (errno != 0 or written == 0) proc_exit(3);
        offset += written;
    }
}

fn findJsonNumber(input: []const u8, key: []const u8) usize {
    var i: usize = 0;
    while (i + key.len <= input.len) : (i += 1) {
        if (!startsWith(input[i..], key)) continue;
        i += key.len;
        while (i < input.len and input[i] != ':') : (i += 1) {}
        if (i < input.len) i += 1;
        while (i < input.len and (input[i] == ' ' or input[i] == '\t' or input[i] == '\n' or input[i] == '\r')) : (i += 1) {}

        var value: usize = 0;
        var saw_digit = false;
        while (i < input.len and input[i] >= '0' and input[i] <= '9') : (i += 1) {
            saw_digit = true;
            value = value * 10 + (input[i] - '0');
        }
        return if (saw_digit) value else 0;
    }
    return 0;
}

fn startsWith(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (needle, 0..) |c, i| {
        if (haystack[i] != c) return false;
    }
    return true;
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
        var len: usize = 0;
        while (true) {
            tmp[len] = '0' + @as(u8, @intCast(n % 10));
            len += 1;
            n /= 10;
            if (n == 0) break;
        }
        while (len > 0) {
            len -= 1;
            self.writeByte(tmp[len]);
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
