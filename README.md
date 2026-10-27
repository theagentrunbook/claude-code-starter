# claude-code-starter

A small, tested `.claude/` directory for [Claude Code](https://code.claude.com/docs): two subagents and one guard hook you can drop into any repo. Every config key was checked against the official docs (October 2026), and the hook ships with a zero-cost self-test.

## What's inside

| File | What it does |
|---|---|
| `.claude/agents/reviewer.md` | A **read-only reviewer** subagent. Its `tools:` allowlist is `Read, Grep, Glob`, so it cannot edit your code even if asked. (Omit `tools` and a subagent inherits every tool, Edit and Bash included.) |
| `.claude/agents/scout.md` | A **scout** on `model: haiku` for "where is X / what calls Y". It runs in its own context window, so search noise never reaches your main conversation. |
| `.claude/hooks/guard.sh` | A **PreToolUse guard** that blocks destructive shell commands (`rm -rf` in any flag order, plain force-pushes, `mkfs`, raw `dd` to a disk) with exit code 2 and tells Claude *why*, so it changes course. It still allows `git push --force-with-lease`. |
| `.claude/settings.json` | Wires the guard to `Bash` and `PowerShell` with `"onFailure": "block"`, so a crashing guard fails closed, not open. |
| `scripts/test-guard.sh` | Feeds fake payloads into the guard and checks exit codes. No model call, no tokens. |

## Install

```bash
# from your repo root
git clone https://github.com/theagentrunbook/claude-code-starter /tmp/ccs
cp -r /tmp/ccs/.claude .
bash /tmp/ccs/scripts/test-guard.sh   # expect: failed=0
```

Already have a `.claude/settings.json`? Merge the `hooks.PreToolUse` block by hand instead of overwriting.

Needs `bash` plus `jq` **or** `python3` for JSON parsing. macOS, Linux, and Windows via Git Bash or WSL.

## Use

- Ask Claude: "use the reviewer subagent on my last change." It returns findings by severity with `file:line` and never edits.
- Ask: "use the scout to find everything that touches the auth middleware."
- Try to make Claude run `rm -rf /`. The guard blocks it and Claude sees the reason.

## Three gotchas worth knowing

1. **Exit 1 is not a block.** Only exit 2 blocks a PreToolUse call. A guard that crashes with exit 1 lets the command run, which is why `onFailure: "block"` is set (Claude Code v2.1.295+).
2. **A regex is a speed bump, not a sandbox.** Pair the guard with `permissions.deny` rules for anything truly irreversible.
3. **Frontmatter typos fail silently.** `Tools:` or `allowed_tools:` is ignored with no error, and your "read-only" agent can write again. Test it once: ask the reviewer to create a file.

## Want more?

This repo is 3 of the 20 plays in **The Claude Code Power-User Playbook**. The rest cover a "tests must pass" Stop gate that can't trap your agent, auto-format hooks, session-start context, live-data skills, human-only commands, MCP at scale, and headless `claude -p` automation.

- Free 5-play sampler (PDF): https://agentrunbook.gumroad.com/l/sampler
- The Playbook, 20 plays: https://agentrunbook.gumroad.com/l/playbook
- The full Kit, a drop-in `.claude/` with 3 agents, 4 hooks, 4 skills, MCP config and a headless script: https://agentrunbook.gumroad.com/l/kit
- One verified play a week: https://theagentrunbook.substack.com

These are my own products. This repo stays free and complete on its own.

## License

MIT. Independent project, not affiliated with or endorsed by Anthropic. "Claude" and "Claude Code" are used descriptively.
