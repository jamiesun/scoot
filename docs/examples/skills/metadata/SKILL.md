---
name: metadata
description: Demonstrates review metadata for a local Scoot skill.
capabilities: [instructions, references]
allowed_tools: [file_read, grep, glob]
scope: workflow
---

# Metadata Skill

Use this template when a skill should be reviewable before installation.

The front matter declares what the skill contains and which built-in tools it
expects the agent may use. These declarations are documentation and packaging
metadata only. They do not grant permissions and do not bypass Scoot policy
gates.
