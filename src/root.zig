//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const zap = @import("zap");

const html_content = @embedFile("static/index.html");

const OllamaRequest = struct {
    model: []const u8,
    prompt: []const u8,
    options: RequestOptions,
};

//Only supporting temperature for now
const RequestOptions = struct {
    temperature: f16,
};

var decode_buf: [4096]u8 = undefined;

fn urlDecode(s: []const u8) ![]const u8 {
    if (s.len > 4096) return error.TooLong;
    var i: usize = 0;
    var j: usize = 0;
    while (i < s.len) {
        if (s[i] == '%') {
            if (i + 2 < s.len) {
                const hex = s[i + 1 .. i + 3];
                const byte = std.fmt.parseInt(u8, hex, 16) catch '?';
                decode_buf[j] = byte;
                j += 1;
                i += 3;
            } else {
                decode_buf[j] = s[i];
                j += 1;
                i += 1;
            }
        } else {
            decode_buf[j] = s[i];
            j += 1;
            i += 1;
        }
    }
    return decode_buf[0..j];
}

pub fn server() !void {
    var listener = zap.HttpListener.init(.{
        .port = 3999,
        .on_request = on_request,
        .log = true,
    });

    try listener.listen();

    std.log.info("Listening on 0.0.0.0:3999", .{});

    zap.start(.{
        .threads = 1,
        .workers = 1,
    });
}

const PromptRequest = struct {
    prompt: []const u8,
};

fn getQueryParam(query: []const u8, key: []const u8) ?[]const u8 {
    if (query.len == 0) return null;
    var start: usize = 0;
    while (start < query.len) {
        const amp = std.mem.indexOfScalarPos(u8, query, start, '&') orelse query.len;
        const pair = query[start..amp];
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            const k = pair[0..eq];
            const v = pair[eq + 1 ..];
            if (std.mem.eql(u8, k, key)) return v;
        } else if (std.mem.eql(u8, pair, key)) {
            return ""; // key without value
        }
        if (amp == query.len) break;
        start = amp + 1;
    }
    return null;
}

fn on_request(r: zap.Request) !void {
    const allocator = std.heap.raw_c_allocator;
    const path = r.path orelse "";
    const query = r.query orelse "";
    const method = r.method orelse "";
    std.log.info("Handling request: path='{s}', query='{s}', method='{s}'", .{ path, query, method });

    var actual_path = path;
    var actual_query = query;

    if (std.mem.indexOf(u8, path, "?")) |qpos| {
        actual_path = path[0..qpos];
        actual_query = path[qpos + 1 ..];
    }

    std.log.info("actual_path: {s}, method: {s}", .{ actual_path, method });

    // Simple non-streaming text endpoint
    if (std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, actual_path, "/generate")) {
        std.log.info("Handling /generate request with path: {s}", .{actual_path});

        const raw_prompt = getQueryParam(actual_query, "prompt") orelse null;
        if (raw_prompt == null) {
            r.setStatus(.bad_request);
            r.setHeader("Content-Type", "text/plain") catch {};
            r.setHeader("Access-Control-Allow-Origin", "*") catch {};
            r.sendBody("Missing prompt parameter\n") catch {};
            return;
        }

        const prompt = urlDecode(raw_prompt.?) catch |err| {
            std.log.err("Failed to decode query prompt: {s}, error: {}", .{ raw_prompt.?, err });
            r.setStatus(.bad_request);
            r.setHeader("Content-Type", "text/plain") catch {};
            r.setHeader("Access-Control-Allow-Origin", "*") catch {};
            r.sendBody("Invalid prompt encoding\n") catch {};
            return;
        };

        send_llm_request_text(r, allocator, prompt);
        return;
    }

    r.sendBody(html_content) catch {};
}

// Removed SSE endpoint and related function

pub fn send_llm_request_text(r: zap.Request, allocator: std.mem.Allocator, prompt: []const u8) void {
    const payload = OllamaRequest{
        .model = "gemma3:27b-it-qat",
        .prompt = prompt,
        .options = RequestOptions{ .temperature = @as(f16, 0.7) },
    };

    // Escape prompt for JSON
    var escaped_prompt_buf = std.ArrayList(u8).initCapacity(allocator, 0) catch {
        r.setStatus(.internal_server_error);
        r.setHeader("Content-Type", "text/plain") catch {};
        r.setHeader("Access-Control-Allow-Origin", "*") catch {};
        r.sendBody("Internal server error\n") catch {};
        return;
    };
    defer escaped_prompt_buf.deinit(allocator);

    for (payload.prompt) |c| {
        switch (c) {
            '"' => escaped_prompt_buf.appendSlice(allocator, "\\\"") catch {},
            '\\' => escaped_prompt_buf.appendSlice(allocator, "\\\\") catch {},
            '\n' => escaped_prompt_buf.appendSlice(allocator, "\\n") catch {},
            '\r' => escaped_prompt_buf.appendSlice(allocator, "\\r") catch {},
            '\t' => escaped_prompt_buf.appendSlice(allocator, "\\t") catch {},
            else => escaped_prompt_buf.append(allocator, c) catch {},
        }
    }

    const escaped_prompt = escaped_prompt_buf.items;
    const json_str = std.fmt.allocPrint(allocator, "{{\"model\":\"{s}\",\"prompt\":\"{s}\",\"stream\":false,\"options\":{{\"temperature\":{d}}}}}\n", .{
        payload.model,
        escaped_prompt,
        payload.options.temperature,
    }) catch {
        r.setStatus(.internal_server_error);
        r.setHeader("Content-Type", "text/plain") catch {};
        r.setHeader("Access-Control-Allow-Origin", "*") catch {};
        r.sendBody("Internal server error\n") catch {};
        return;
    };
    defer allocator.free(json_str);

    var process = std.process.Child.init(&[_][]const u8{
        "curl",                                "-s", "-X",                             "POST",
        "http://localhost:11434/api/generate", "-H", "Content-Type: application/json", "-d",
        json_str,
    }, allocator);

    process.stdout_behavior = .Pipe;
    process.stderr_behavior = .Ignore;

    process.spawn() catch {
        r.setStatus(.internal_server_error);
        r.setHeader("Content-Type", "text/plain") catch {};
        r.setHeader("Access-Control-Allow-Origin", "*") catch {};
        r.sendBody("Error spawning curl\n") catch {};
        return;
    };

    const stdout = process.stdout orelse {
        r.setStatus(.internal_server_error);
        r.setHeader("Content-Type", "text/plain") catch {};
        r.setHeader("Access-Control-Allow-Origin", "*") catch {};
        r.sendBody("No stdout from curl\n") catch {};
        return;
    };

    var response_buf = std.ArrayList(u8).initCapacity(allocator, 0) catch {
        r.setStatus(.internal_server_error);
        r.setHeader("Content-Type", "text/plain") catch {};
        r.setHeader("Access-Control-Allow-Origin", "*") catch {};
        r.sendBody("Internal server error\n") catch {};
        return;
    };
    defer response_buf.deinit(allocator);
    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = stdout.read(&read_buf) catch break;
        if (n == 0) break;
        response_buf.appendSlice(allocator, read_buf[0..n]) catch {};
    }

    _ = process.wait() catch {};

    // Ollama returns a single JSON object when stream=false
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_buf.items, .{}) catch {
        r.setStatus(.internal_server_error);
        r.setHeader("Content-Type", "text/plain") catch {};
        r.setHeader("Access-Control-Allow-Origin", "*") catch {};
        r.sendBody("Invalid response from Ollama\n") catch {};
        return;
    };
    defer parsed.deinit();

    if (parsed.value.object.get("response")) |resp| {
        if (resp == .string) {
            r.setStatus(.ok);
            r.setHeader("Content-Type", "text/plain; charset=utf-8") catch {};
            r.setHeader("Access-Control-Allow-Origin", "*") catch {};
            r.sendBody(resp.string) catch {};
            return;
        }
    }

    r.setStatus(.internal_server_error);
    r.setHeader("Content-Type", "text/plain") catch {};
    r.setHeader("Access-Control-Allow-Origin", "*") catch {};
    r.sendBody("No response from Ollama\n") catch {};
}
