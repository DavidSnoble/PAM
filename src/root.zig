//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const zap = @import("zap");

const html_content = @embedFile("static/index.html");

const OllamaRequest = struct {
    model: []const u8,
    prompt: []const u8,
    stream: bool,
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
    if (std.mem.startsWith(u8, actual_path, "/stream/") and std.mem.eql(u8, method, "GET")) {
        std.log.info("Handling /stream request with path: {s}", .{actual_path});
        const encoded_prompt = actual_path[8..];
        std.log.info("Encoded prompt: {s}", .{encoded_prompt});
        const prompt = urlDecode(encoded_prompt) catch |err| {
            std.log.err("Failed to decode prompt: {s}, error: {}", .{ encoded_prompt, err });
            r.sendBody("Invalid prompt encoding\n") catch {};
            return;
        };
        defer allocator.free(prompt);
        send_llm_request_sse(r, allocator, prompt);
        return;
    }

    r.sendBody(html_content) catch {};
}

pub fn send_llm_request_sse(r: zap.Request, allocator: std.mem.Allocator, prompt: []const u8) void {
    const payload = OllamaRequest{
        .model = "gemma3:27b-it-qat",
        .prompt = prompt,
        .stream = true,
        .options = RequestOptions{ .temperature = @as(f16, 0.7) },
    };

    // Manually escape the prompt for JSON
    var escaped_prompt_buf = std.ArrayList(u8).initCapacity(allocator, 0) catch {
        std.log.err("Failed to allocate escaped prompt buffer", .{});
        // r.setStatus(.ok);
        r.setHeader("Content-Type", "text/event-stream") catch {};
        r.setHeader("Cache-Control", "no-cache") catch {};
        r.setHeader("Transfer-Encoding", "chunked") catch {};
        r.setHeader("Access-Control-Allow-Origin", "*") catch {};
        const error_event = "data: Internal server error\n\n";
        _ = zap.fio.http_send_body(r.h, @as(*anyopaque, @ptrFromInt(@intFromPtr(error_event.ptr))), error_event.len);
        zap.fio.http_finish(r.h);
        r.markAsFinished(true);
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

    const json_str = std.fmt.allocPrint(allocator, "{{\"model\":\"{s}\",\"prompt\":\"{s}\",\"stream\":{},\n\"options\":{{\"temperature\":{d}}}}}\n", .{
        payload.model,
        escaped_prompt,
        payload.stream,
        payload.options.temperature,
    }) catch {
        std.log.err("Failed to allocate JSON string", .{});
        // r.setStatus(.ok);
        r.setHeader("Content-Type", "text/event-stream") catch {};
        r.setHeader("Cache-Control", "no-cache") catch {};
        r.setHeader("Transfer-Encoding", "chunked") catch {};
        r.setHeader("Access-Control-Allow-Origin", "*") catch {};
        const error_event = "data: Internal server error\n\n";
        _ = zap.fio.http_send_body(r.h, @as(*anyopaque, @ptrFromInt(@intFromPtr(error_event.ptr))), error_event.len);
        zap.fio.http_finish(r.h);
        r.markAsFinished(true);
        return;
    };
    defer allocator.free(json_str);

    var process = std.process.Child.init(&[_][]const u8{
        "curl",
        "--no-buffer",
        "-s", // silent
        "-X",
        "POST",
        "http://localhost:11434/api/generate",
        "-H",
        "Content-Type: application/json",
        "-d",
        json_str,
    }, allocator);

    process.stdout_behavior = .Pipe;
    process.stderr_behavior = .Ignore;

    process.spawn() catch |err| {
        std.log.err("Failed to spawn curl: {}", .{err});
        // r.setStatus(.ok);
        r.setHeader("Content-Type", "text/event-stream") catch {};
        r.setHeader("Cache-Control", "no-cache") catch {};
        r.setHeader("Transfer-Encoding", "chunked") catch {};
        r.setHeader("Access-Control-Allow-Origin", "*") catch {};
        const error_event = "data: Error spawning curl\n\n";
        _ = zap.fio.http_send_body(r.h, @as(*anyopaque, @ptrFromInt(@intFromPtr(error_event.ptr))), error_event.len);
        zap.fio.http_finish(r.h);
        r.markAsFinished(true);
        return;
    };

    // r.setStatus(.ok);
    r.setHeader("Content-Type", "text/event-stream") catch {};
    r.setHeader("Cache-Control", "no-cache") catch {};
    r.setHeader("Connection", "keep-alive") catch {};
    r.setHeader("Transfer-Encoding", "chunked") catch {};
    r.setHeader("Access-Control-Allow-Origin", "*") catch {};
    r.setHeader("Access-Control-Allow-Headers", "Cache-Control") catch {};

    const stdout = process.stdout orelse {
        const error_event = "data: Error: No stdout from curl\n\n";
        _ = zap.fio.http_send_body(r.h, @as(*anyopaque, @ptrFromInt(@intFromPtr(error_event.ptr))), error_event.len);
        zap.fio.http_finish(r.h);
        r.markAsFinished(true);
        return;
    };

    var line_buf = std.ArrayListUnmanaged(u8){};
    defer line_buf.deinit(allocator);

    var has_sent_data = false;
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = stdout.read(&buf) catch break;
        if (n == 0) break;
        for (buf[0..n]) |c| {
            if (c == '\n') {
                const line = line_buf.items;
                if (line.len > 0) {
                    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| {
                        std.log.err("Failed to parse JSON: {s}, error: {}", .{ line, err });
                        const error_msg = std.fmt.allocPrint(allocator, "data: Error parsing response: {s}\n\n", .{line}) catch continue;
                        defer allocator.free(error_msg);
                        _ = zap.fio.http_send_body(r.h, @as(*anyopaque, @ptrFromInt(@intFromPtr(error_msg.ptr))), error_msg.len);
                        continue;
                    };
                    defer parsed.deinit();

                    if (parsed.value.object.get("response")) |response_val| {
                        if (response_val == .string) {
                            const event = std.fmt.allocPrint(allocator, "data: {s}\n\n", .{response_val.string}) catch continue;
                            defer allocator.free(event);
                            _ = zap.fio.http_send_body(r.h, @as(*anyopaque, @ptrFromInt(@intFromPtr(event.ptr))), event.len);
                            has_sent_data = true;
                        }
                    }

                    if (parsed.value.object.get("done")) |done_val| {
                        if (done_val == .bool and done_val.bool) {
                            const done_event = "data: DONE\n\n";
                            _ = zap.fio.http_send_body(r.h, @as(*anyopaque, @ptrFromInt(@intFromPtr(done_event.ptr))), done_event.len);
                            zap.fio.http_finish(r.h);
                            r.markAsFinished(true);
                            break;
                        }
                    }
                }
                line_buf.clearRetainingCapacity();
            } else {
                line_buf.append(allocator, c) catch {};
            }
        }
    }

    const term = process.wait() catch |err| {
        std.log.err("Wait failed: {}", .{err});
        const error_event = "data: Error waiting for curl\n\n";
        _ = zap.fio.http_send_body(r.h, @as(*anyopaque, @ptrFromInt(@intFromPtr(error_event.ptr))), error_event.len);
        zap.fio.http_finish(r.h);
        r.markAsFinished(true);
        return;
    };

    if (term != .Exited or term.Exited != 0) {
        const error_event = "data: Error: Failed to get response from Ollama\n\n";
        _ = zap.fio.http_send_body(r.h, @as(*anyopaque, @ptrFromInt(@intFromPtr(error_event.ptr))), error_event.len);
    } else if (!has_sent_data) {
        // If no data was sent and curl succeeded, send a no response message
        const no_response_event = "data: No response from Ollama\n\n";
        _ = zap.fio.http_send_body(r.h, @as(*anyopaque, @ptrFromInt(@intFromPtr(no_response_event.ptr))), no_response_event.len);
    }

    zap.fio.http_finish(r.h);
    r.markAsFinished(true);
}
