# CI、发布与文档

本仓库包含 GitHub Actions 工作流：

- CI：构建并测试 Zig 项目。
- Release：推送版本标签时构建发布产物。
- mdBook：构建并发布双语文档站点。

## 本地检查

```sh
zig build
zig build test
mdbook build book/en
mdbook build book/zh
mkdir -p site
cp book/site-index.html site/index.html
mkdir -p site/assets
cp docs/assets/scoot-logo.svg docs/assets/scoot-favicon.svg docs/assets/scoot-favicon.png site/assets/
```

## 文档站点

英文书构建到 `site/en`，中文书构建到 `site/zh`。共享入口页是 `book/site-index.html`。

每本书顶部都提供语言切换链接。

## 发布产物

推送版本标签后会发布这些目标：

- `linux-amd64`
- `linux-arm64`
- `linux-armv7`
- `macos-amd64`
- `macos-arm64`

每个目标上传一个 `.tar.gz` 压缩包和一个 `.sha256` 校验文件。
