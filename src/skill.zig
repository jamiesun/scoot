//! Skill 机制（必备能力）：把"打包好的能力 + 指令集"以目录形式挂载给 Agent。
//!
//! 一个 Skill 就是一个目录：
//!   <skill>/
//!     SKILL.md       必需：YAML front-matter(name, description, [when_to_use],
//!                    [allowed_tools]) + Markdown 正文指令
//!     scripts/       可选：可被工具沙盒执行的脚本（同样受硬超时约束）
//!     references/    可选：按需加载的参考资料
//!     assets/        可选：模板等资源
//!
//! 渐进式披露（服务"轻量化"，避免上下文爆炸）：
//!   1) 发现：扫描各 skill 路径，只解析 front-matter（name+description）建轻量索引；
//!   2) 注入：把可用 skill 的 name+description 放进 system context；
//!   3) 激活：模型选中某 skill 时，才按需加载其 SKILL.md 正文与引用资源；
//!   4) 执行：skill 自带脚本经统一工具沙盒执行（硬超时 + 防御校验）。
const std = @import("std");

/// 单个 skill 的元数据（来自 SKILL.md front-matter）。
pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    /// skill 目录的绝对路径。
    dir: []const u8,
    /// 该 skill 允许使用的工具名白名单；空表示继承默认。
    allowed_tools: []const []const u8 = &.{},
    /// 正文是否已加载（渐进式披露）。
    loaded: bool = false,
    /// SKILL.md 正文，仅在激活后填充。
    body: []const u8 = "",
};

/// Skill 注册表：聚合多个 skill 路径下发现的 skill。
pub const Registry = struct {
    skills: std.ArrayList(Skill) = .empty,

    /// 扫描一个 skill 路径，解析其中每个子目录的 front-matter 并登记。
    /// TODO: 用 Io 遍历目录、读取 SKILL.md 头部、解析 name/description/allowed_tools。
    pub fn discover(self: *Registry, gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
        _ = self;
        _ = gpa;
        _ = io;
        _ = path;
        return error.NotImplemented;
    }

    /// 把当前已发现 skill 的 name+description 渲染为可注入 system context 的清单。
    /// TODO: 仅输出元数据，不含正文（渐进式披露）。
    pub fn manifest(self: *Registry, arena: std.mem.Allocator) ![]const u8 {
        _ = self;
        _ = arena;
        return error.NotImplemented;
    }

    /// 按名查找 skill。
    pub fn find(self: *Registry, name: []const u8) ?*Skill {
        for (self.skills.items) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    /// 激活（按需加载）某 skill 的正文与引用资源。
    /// TODO: 读取 SKILL.md 正文填入 body，置 loaded=true。
    pub fn activate(self: *Registry, io: std.Io, name: []const u8) !*Skill {
        _ = io;
        return self.find(name) orelse error.SkillNotFound;
    }

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        self.skills.deinit(gpa);
    }
};

test {
    std.testing.refAllDecls(@This());
}
