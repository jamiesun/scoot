# CI, Release, And Docs

This repository includes GitHub Actions workflows for:

- CI: build and test the Zig project.
- Release: build release artifacts when a version tag is pushed.
- mdBook: build and publish the bilingual documentation site.

## Local Checks

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

## Documentation Site

The English book builds to `site/en`; the Chinese book builds to `site/zh`. The shared landing page is `book/site-index.html`.

Each book includes a language switch link in the top menu.

## Release Artifacts

Tagged releases publish these targets:

- `linux-amd64`
- `linux-arm64`
- `linux-armv7`
- `macos-amd64`
- `macos-arm64`

Each target uploads a `.tar.gz` archive and a `.sha256` checksum.
