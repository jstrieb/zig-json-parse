const std = @import("std");

const Result = struct { JsonType, []const u8 };
const ParseError = error.ParseError;
const NotImplementedError = error.NotImplementedError;

const JsonType = union(enum) {
    string: []const u8,
    number: f64,
    boolean: bool,
    object: std.StringHashMap(JsonType),
    array: []const JsonType,
    null: ?void,

    const Self = @This();

    pub fn print(self: *const Self) void {
        // TODO
        std.debug.print("{any}\n", .{self});
        switch (self.*) {
            .string => {},
            .number => {},
            .boolean => {},
            .object => {},
            .array => {},
            .null => {},
        }
    }
};

fn skipWhitespace(s: []const u8) []const u8 {
    return std.mem.trimLeft(u8, s, " \t\n\r");
}

fn parseNumber(s: []const u8, _: std.mem.Allocator) !Result {
    // TODO: More robust float parsing. For example, this fails with numbers
    // with trailing minus signs.
    const end = std.mem.indexOfNone(u8, s, "+-.e0123456789") orelse s.len;
    const f: f64 = std.fmt.parseFloat(f64, s[0..end]) catch return ParseError;
    return .{ .{ .number = f }, s[end..] };
}

fn parseBool(s: []const u8, _: std.mem.Allocator) !Result {
    if (s.len == 0) return ParseError;
    if (std.mem.startsWith(u8, s, "true")) {
        return .{ .{ .boolean = true }, s["true".len..] };
    } else if (std.mem.startsWith(u8, s, "false")) {
        return .{ .{ .boolean = false }, s["false".len..] };
    } else {
        return ParseError;
    }
}

fn parseNull(s: []const u8, _: std.mem.Allocator) !Result {
    if (s.len == 0) return ParseError;
    if (std.mem.startsWith(u8, s, "null")) {
        return .{ .{ .null = null }, s["null".len..] };
    } else {
        return ParseError;
    }
}

fn parseHexDigit(c: u8) !u8 {
    return switch (c) {
        '0' => 0,
        '1' => 1,
        '2' => 2,
        '3' => 3,
        '4' => 4,
        '5' => 5,
        '6' => 6,
        '7' => 7,
        '8' => 8,
        '9' => 9,
        'A', 'a' => 10,
        'B', 'b' => 11,
        'C', 'c' => 12,
        'D', 'd' => 13,
        'E', 'e' => 14,
        'F', 'f' => 15,
        else => return ParseError,
    };
}

fn parseHexDigits(s: []const u8) !u32 {
    var result: u32 = 0;
    for (s) |c| {
        result = result * 16 + try parseHexDigit(c);
    }
    return result;
}

fn parseString(s: []const u8, allocator: std.mem.Allocator) !Result {
    if (s.len == 0) return ParseError;
    if (s[0] != '"') return ParseError;

    var rest = s[1..];
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    var i: usize = 0;
    while (rest[i] != '"') : (i += 1) {
        switch (rest[i]) {
            '\x00'...'\x1F' => return ParseError,
            '\\' => {
                i += 1;
                try result.append(switch (rest[i]) {
                    '"' => '"',
                    '\\' => '\\',
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    '/' => '/',
                    'b' => '\x08',
                    'f' => '\x0C',
                    'u' => blk: {
                        i += 1;
                        // TODO: Don't discard unicode characters
                        _ = try parseHexDigits(rest[i .. i + 4]);
                        i += 3;
                        break :blk '\x00';
                    },
                    else => return ParseError,
                });
            },
            else => try result.append(rest[i]),
        }
    }

    return .{ .{ .string = try result.toOwnedSlice() }, rest[i + 1 ..] };
}

fn parseMember(s: []const u8, allocator: std.mem.Allocator) !struct {
    []const u8,
    JsonType,
    []const u8,
} {
    if (s.len == 0) return ParseError;
    const key, var rest = try parseString(skipWhitespace(s), allocator);
    rest = skipWhitespace(rest);
    if (rest[0] != ':') return ParseError;
    const result, rest = try parseElement(rest[1..], allocator);
    return .{ key.string, result, rest };
}

fn parseObject(s: []const u8, allocator: std.mem.Allocator) !Result {
    if (s.len == 0) return ParseError;
    if (s[0] != '{') return ParseError;

    var map = std.StringHashMap(JsonType).init(allocator);
    errdefer map.deinit();

    var rest = s[1..];
    while (rest[0] != '}') {
        const key, const value, rest = try parseMember(rest, allocator);
        try map.put(key, value);
        if (rest[0] != ',') break;
        rest = rest[1..];
    }
    if (rest[0] != '}') return ParseError;

    return .{ .{ .object = map }, skipWhitespace(rest)[1..] };
}

fn parseArray(s: []const u8, allocator: std.mem.Allocator) !Result {
    if (s.len == 0) return ParseError;
    if (s[0] != '[') return ParseError;

    var list = std.ArrayList(JsonType).init(allocator);
    defer list.deinit();

    var rest = s[1..];
    while (rest[0] != ']') {
        const value, rest = try parseElement(rest, allocator);
        try list.append(value);
        if (rest[0] != ',') break;
        rest = rest[1..];
    }
    if (rest[0] != ']') return ParseError;

    return .{ .{ .array = try list.toOwnedSlice() }, skipWhitespace(rest)[1..] };
}

fn parseValue(s: []const u8, allocator: std.mem.Allocator) !Result {
    if (parseObject(s, allocator)) |r| {
        return r;
    } else |err| switch (err) {
        ParseError => {},
        else => return err,
    }
    if (parseArray(s, allocator)) |r| {
        return r;
    } else |err| switch (err) {
        ParseError => {},
        else => return err,
    }
    if (parseString(s, allocator)) |r| {
        return r;
    } else |err| switch (err) {
        ParseError => {},
        else => return err,
    }
    if (parseNumber(s, allocator)) |r| {
        return r;
    } else |err| switch (err) {
        ParseError => {},
        else => return err,
    }
    if (parseBool(s, allocator)) |r| {
        return r;
    } else |err| switch (err) {
        ParseError => {},
        else => return err,
    }
    if (parseNull(s, allocator)) |r| {
        return r;
    } else |err| switch (err) {
        ParseError => {},
        else => return err,
    }
    return ParseError;
}

// Explicit error sets are required for recursive functions
// https://github.com/ziglang/zig/issues/763
fn parseElement(
    s: []const u8,
    allocator: std.mem.Allocator,
) error{ ParseError, NotImplementedError, OutOfMemory }!Result {
    const result, const rest = try parseValue(skipWhitespace(s), allocator);
    return .{ result, skipWhitespace(rest) };
}

fn parseJson(s: []const u8, allocator: std.mem.Allocator) !JsonType {
    const result, const rest = try parseElement(s, allocator);
    if (rest.len > 0) {
        return ParseError;
    }
    return result;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    const stdin = std.io.getStdIn();
    const GB = 1024 * 1024 * 1024;
    const input = try stdin.readToEndAlloc(allocator, 4 * GB);

    const o = try parseJson(input, allocator);
    // TODO: Remove
    o.print();
}
