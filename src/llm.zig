//! LLM 后端适配：仅对接 OpenAI `/v1/chat/completions`。
//! 强制 response_format=json_schema 与 tool_calling strict=true；
//! 绝不为非 OpenAI 协议编写胶水代码（见 ROADMAP 非目标）。
const std = @import("std");

pub const Role = enum { system, user, assistant, tool };

pub const Message = struct {
    role: Role,
    content: []const u8,
};

/// 一次 chat/completions 的结果（已通过防弹 JSON 解析）。
pub const Completion = struct {
    content: []const u8,
    // TODO: tool_calls、finish_reason、usage 等字段。
};

pub const Client = struct {
    base_url: []const u8,
    model: []const u8,

    pub fn init(base_url: []const u8, model: []const u8) Client {
        return .{ .base_url = base_url, .model = model };
    }

    /// 发起一次 chat/completions 请求。
    /// TODO: 1) 组装请求体（强制 json_schema/strict）2) HTTP POST
    ///       3) 防弹 JSON 解析：脏数据不 panic，包装为 System Error 触发重试。
    pub fn chat(self: *Client, arena: std.mem.Allocator, messages: []const Message) !Completion {
        _ = self;
        _ = arena;
        _ = messages;
        return error.NotImplemented;
    }
};

test {
    std.testing.refAllDecls(@This());
}
