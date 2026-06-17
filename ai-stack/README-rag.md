# RAG System — Usage Guide

The MCP server at `hermes/mcp/openwebui-mcp.py` bridges Hermes and Claude Code to the Open WebUI knowledge base. Five tools are available to any AI client with the MCP server registered.

## Four-tier structure

| Tier | KB name pattern | What belongs here |
|------|----------------|-------------------|
| 1 | `framework-{name}` | PHP framework/CMS reference — Drupal hooks, Symfony services, WordPress actions, CakePHP conventions |
| 2 | `project-{slug}` | Per-project source code + project-specific config and devops |
| 3 | `common-issues` | Cross-cutting gotchas, bugs, non-obvious fixes across all stacks |
| 4 | `devops-general` | Infrastructure — Docker, k8s, Linux, nginx, SSL, OS patterns |

OS-specific content goes in Tier 4. Project-specific OS config (e.g., `.env`, custom nginx conf) goes in the project's Tier 2 KB.

---

## Starting a new project

### 1. Index the project source

```
rag_index_project(path="/path/to/myproject")
```

This walks the project tree, skips excluded paths (vendor/, var/, node_modules/, web/core/, .git/), and uploads all `.php`, `.twig`, `.yml`, `.yaml`, `.env.example`, and `.md` files into `project-{dirname}`. The KB is cleared and rebuilt on each call.

If the project name (directory basename) isn't descriptive, pass an explicit slug:

```
rag_index_project(path="/path/to/myproject", project="client-portal")
```

### 2. Auto-detection

When `RAG_CWD_DETECT=1` (the default), `rag_search` infers the project slug and framework from the working directory automatically. If `composer.json` declares `drupal/core`, the `framework-drupal` KB is included in default searches without you having to specify it.

Frameworks detected: Drupal, Symfony, WordPress, CakePHP, Laravel.

---

## Searching

Default search covers Tiers 1–3 (framework, project, common-issues). Add Tier 4 when the question is infrastructure-related.

```
# Auto-detected context (CWD must be the project root)
rag_search(query="how does the routing system handle middleware")

# Explicit context when CWD is wrong
rag_search(query="event subscribers", framework="symfony", project="my-app")

# DevOps question — add Tier 4
rag_search(query="nginx upstream timeout config", tiers=["devops-general", "common-issues"])

# All tiers
rag_search(query="database connection pooling", tiers=["framework","project","common-issues","devops-general"])

# Increase results
rag_search(query="service container", k=10)
```

---

## Adding content

### Add a common issue (Tier 3)

Use this when you discover a non-obvious bug, a tricky fix, or anything that would waste time again.

```
rag_add_issue(
    name="drupal-entity-cache-invalidation-after-hook-update-n",
    content="After hook_update_N runs, entity caches are not automatically cleared. Call \\Drupal::entityTypeManager()->clearCachedDefinitions() and drupal_flush_all_caches() explicitly, or the old field definitions remain in the runtime cache for the rest of the request.",
    tags=["drupal", "cache", "update-hook", "entity"]
)
```

Tags are free-form strings. Use lowercase, hyphenated. Include framework, symptom keywords, and any relevant OS/stack tag (e.g., `linux`, `docker`, `nginx`).

### Add a framework reference doc (Tier 1)

```
rag_add_doc(
    name="symfony-messenger-transport-config",
    content="...",
    tier="framework",
    framework="symfony",
    tags=["symfony", "messenger", "async", "transport", "rabbitmq"]
)
```

### Add a devops reference doc (Tier 4)

```
rag_add_doc(
    name="k8s-resource-limits-oom-patterns",
    content="...",
    tier="devops-general",
    tags=["kubernetes", "oom", "memory", "resources", "linux"]
)
```

### Add a project-specific doc (Tier 2)

```
rag_add_doc(
    name="my-app-deployment-runbook",
    content="...",
    tier="project",
    project="my-app",
    tags=["deployment", "docker", "nginx"]
)
```

Calling `rag_add_doc` with the same `name` replaces the existing file — safe to re-run.

---

## Inspecting the knowledge base

```
rag_list_kbs()
```

Lists all KBs grouped by tier with file counts and IDs. Use this to verify indexing worked or to see what tiers exist.

---

## Registering the MCP server

### Hermes

Already configured in `~/.hermes/config.yaml` under `mcp_servers.openwebui-rag`. Update `OPENWEBUI_TOKEN` when the JWT expires (tokens expire every ~30 days; generate a new one from Open WebUI → Settings → Account → API Keys).

### Claude Code

Run once per machine (user scope — persists across projects):

```bash
claude mcp add -s user openwebui-rag \
  -e OPENWEBUI_URL=http://localhost:3000 \
  -e OPENWEBUI_TOKEN="<your-token>" \
  -e RAG_CWD_DETECT=1 \
  -- python3 /home/devuser/fedora-build/hermes/mcp/openwebui-mcp.py
```

Verify: `claude mcp list` should show `openwebui-rag`.

### Cursor

Copy `ai-stack/cursor-mcp.dist.json` to `.cursor/mcp.json` in the project root and fill in the token:

```json
{
  "mcpServers": {
    "openwebui-rag": {
      "command": "python3",
      "args": ["/home/devuser/fedora-build/hermes/mcp/openwebui-mcp.py"],
      "env": {
        "OPENWEBUI_URL":   "http://localhost:3000",
        "OPENWEBUI_TOKEN": "<your-token>",
        "RAG_CWD_DETECT":  "1"
      }
    }
  }
}
```

`rag_index_project` writes this file automatically when run from the project root (pending Phase 5).

---

## Session workflow

At the end of any significant working session:

1. Run `rag_add_issue` for any gotchas discovered
2. Run `rag_add_doc` for any architectural decisions or runbooks written
3. Create `docs/sessions/YYYY-MM-DD-summary.md` and upload it:

```
rag_add_doc(
    name="01-sessions--2026-06-17-summary",
    content="...",
    tier="devops-general",
    tags=["session", "summary"]
)
```

---

## Excluded paths — never index directly

The following directories are skipped by `rag_index_project` and should never be read directly by an AI client either. Use RAG Tier 1 for framework internals instead.

- `vendor/`
- `web/core/` (Drupal)
- `node_modules/`
- `var/cache/`, `var/log/`
- `.git/`, `.idea/`, `dist/`, `build/`

---

## Troubleshooting

**"No knowledge bases matched"** — The KB doesn't exist yet. Run `rag_index_project` to create the project KB, or `rag_add_doc` with the appropriate tier to create a framework/devops KB. Run `rag_list_kbs()` to see what exists.

**Token expired (HTTP 401)** — Generate a new API key in Open WebUI (Settings → Account → API Keys) and update `OPENWEBUI_TOKEN` in `~/.hermes/config.yaml` and your `claude mcp` registration.

**Stale results after re-indexing** — Open WebUI ChromaDB updates asynchronously after file upload; wait 5–10 seconds before querying if results look stale.

**MCP timeout in Hermes** — Complex multi-step tool chains can exceed the 60s timeout. Test the MCP server directly:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag_list_kbs","arguments":{}}}' \
  | OPENWEBUI_TOKEN="..." python3 /home/devuser/fedora-build/hermes/mcp/openwebui-mcp.py
```
