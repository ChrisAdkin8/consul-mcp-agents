# Terraform Development Practices for Claude Code

Best practices for working with Terraform in this project using Claude Code.
These are implemented in the project's `.claude/` configuration directory.

## 1. Auto-formatting and validation hooks

**File**: `.claude/settings.json` (`hooks` section)

Two `PostToolUse` hooks run automatically after every `Edit` or `Write` tool call:

| Hook | Trigger | Action |
|---|---|---|
| `terraform fmt` | Any `.tf` file edited | Runs `terraform fmt -recursive` on the `tf/` directory |
| `terraform validate` | Any `.tf` file edited | Runs `terraform validate` in each module/scenario that changed |

These hooks eliminate manual formatting and catch syntax errors immediately after
each edit, before they compound.

**How it works**: The hook checks whether the edited file path contains `tf/` and
only runs for Terraform files. Non-Terraform edits are unaffected.

## 2. Permission rules

**File**: `.claude/settings.json` (`permissions` section)

Permissions are structured in three tiers:

| Tier | Commands | Rationale |
|---|---|---|
| **allow** | `terraform init/plan/fmt/validate/state/output`, `task *`, `kubectl get/describe/logs` | Safe, read-only or local-only operations |
| **ask** | `terraform apply`, `terraform destroy`, `helm uninstall` | Destructive or stateful — require confirmation |
| **deny** | None currently | All commands available with appropriate tier |

This replaces the ad-hoc permission accumulation in `settings.local.json` with
a structured, intentional policy. The local file can still override for personal
preferences.

## 3. Path-scoped Terraform rules

**File**: `.claude/rules/terraform.md`

Path-scoped rules load automatically when Claude edits files matching `tf/**/*.tf`.
They stay out of context for non-Terraform work.

Rules cover:
- Variable descriptions and type constraints
- Sensitive output marking
- `depends_on` usage (implicit deps only)
- Resource naming conventions
- Module output stability
- `for_each` preference over `count` for named resources

## 4. Terraform MCP server

**File**: `.claude/settings.json` (`mcpServers` section)

The [Terraform MCP server](https://www.npmjs.com/package/terraform-mcp-server)
provides structured access to:
- Provider documentation lookups (no need to web search for resource schemas)
- Registry module discovery
- Resource argument and attribute reference

### Setup

The npm package is `terraform-mcp-server` (maintained by HashiCorp engineer thrashr888).
No global install needed — `npx -y` downloads and runs it on demand.

The MCP server is configured in `.claude/settings.json` under `mcpServers`.
It runs as a stdio process and starts automatically when Claude Code needs it.

**Prerequisite**: Node.js must be installed (`brew install node`).

### Usage

When writing Terraform configs, Claude can query the MCP server for:
- Required and optional arguments for any resource type
- Valid attribute values and constraints
- Provider-specific documentation

This reduces hallucinated resource arguments and eliminates web search round-trips
for provider docs.

## Project structure

```
.claude/
├── settings.json          # Project-level: hooks, permissions, MCP servers (VCS)
├── settings.local.json    # Personal overrides (gitignored)
└── rules/
    └── terraform.md       # Path-scoped rules for tf/**/*.tf files
```

## Status

All four practices are implemented and verified:

| # | Practice | Status | Notes |
|---|---|---|---|
| 1 | Auto-formatting/validation hooks | Done | PostToolUse hooks in `.claude/settings.json` |
| 2 | Permission rules | Done | Three-tier allow/ask/deny in `.claude/settings.json` |
| 3 | Path-scoped Terraform rules | Done | `.claude/rules/terraform.md` loads for `tf/**/*.tf` |
| 4 | Terraform MCP server | Done | `terraform-mcp-server` via npx, Node.js installed |

**Important**: The npm package is `terraform-mcp-server`, not `@hashicorp/terraform-mcp-server`.

## Applying changes

These configurations are read by Claude Code at session start. To apply:
1. Restart your Claude Code session (or start a new one)
2. Hooks and rules take effect immediately
3. Node.js is required for the Terraform MCP server (`brew install node` — already installed)
