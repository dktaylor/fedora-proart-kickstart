# Four-Tier RAG — Usage Guide

This system organises your knowledge into four tiers, each with a specific scope. The MCP server (`mcp/openwebui-mcp.py`) bridges AI clients (Claude Code, Hermes, Cursor) to Open WebUI's knowledge bases.

---

## Concepts

### Why four tiers?

A flat single knowledge base forces every query to search everything — framework docs, project code, infrastructure notes, and common bugs all compete for the same result slots. Tiered search lets you be precise: "search my framework docs and this project's code" returns dramatically more relevant results than a global search.

| Tier | KB name pattern | Scope |
|------|----------------|-------|
| 1 | `framework-{name}` | Framework/CMS reference — APIs, hooks, conventions |
| 2 | `project-{slug}` | Per-project source code and project-specific config |
| 3 | `common-issues` | Cross-cutting bugs, gotchas, non-obvious fixes |
| 4 | `devops-general` | Infrastructure — Docker, k8s, nginx, SSL, OS patterns |

### Default search tiers

When you call `rag_search` without specifying tiers, it searches Tiers 1–3:

```
["framework", "project", "common-issues"]
```

Add `"devops-general"` explicitly for infrastructure questions. This keeps the default result set focused on code rather than ops.

### KB naming convention

KB names encode their tier. The MCP server infers tier from the name prefix:

- `framework-symfony`, `framework-drupal`, `framework-wordpress` → Tier 1
- `project-my-app`, `project-client-portal` → Tier 2
- `common-issues` → Tier 3 (exactly this name)
- `devops-general` → Tier 4 (exactly this name)

Any KB whose name doesn't match a prefix is treated as "other" and only appears in `rag_list_kbs` output — it won't be searched unless you pass its name explicitly.

### Auto-detection

When `RAG_CWD_DETECT=1` (default), the MCP server reads the working directory to infer project and framework automatically:

- Project slug = directory basename
- Framework = detected from `composer.json` require fields or directory markers (`web/core/` → drupal, `wp-config.php` → wordpress)

Frameworks detected: Drupal, Symfony, WordPress, CakePHP, Laravel.

---

## Getting started

### Prerequisites

- Docker and Docker Compose
- Python 3.10+
- An Ollama instance (local or remote) or any OpenAI-compatible inference endpoint
- An AI client with MCP support (Claude Code, Hermes, or Cursor)

### 1. Start the stack

```bash
cp .env.example .env
# Edit .env — set OLLAMA_BASE_URL if Ollama is not on localhost
docker compose up -d
```

Open WebUI is now at **http://localhost:3000**.

### 2. Get your API token

1. Open http://localhost:3000, create an account
2. Avatar (bottom-left) → **Settings → Account → API Keys → Create new secret key**
3. Copy the token into `.env` as `OPENWEBUI_TOKEN`

### 3. Register the MCP server

**Claude Code** (run once, user scope — persists across projects):

```bash
claude mcp add -s user openwebui-rag \
  -e OPENWEBUI_URL=http://localhost:3000 \
  -e OPENWEBUI_TOKEN="<your-token>" \
  -e RAG_CWD_DETECT=1 \
  -- python3 /path/to/rag-stack/mcp/openwebui-mcp.py
```

**Hermes** — add to `~/.hermes/config.yaml`:

```yaml
mcp_servers:
  openwebui-rag:
    command: python3
    args: ["/path/to/rag-stack/mcp/openwebui-mcp.py"]
    env:
      OPENWEBUI_URL:   "http://localhost:3000"
      OPENWEBUI_TOKEN: "<your-token>"
      RAG_CWD_DETECT:  "1"
    timeout: 60
```

**Cursor** — copy `templates/cursor-mcp.json` to `.cursor/mcp.json` in the project root and fill in the token.

### 4. Index your first project

Run from within the project directory (auto-detects slug and framework):

```
rag_index_project()
```

Or specify explicitly:

```
rag_index_project(path="/path/to/project", project="my-app")
```

### 5. Search

```
rag_search(query="how does authentication work")
```

---

## Adding and managing tiers

### Adding a framework KB (Tier 1)

Framework KBs hold reference material — API docs, hook lists, service definitions — that you want available across all projects using that framework.

```
rag_add_doc(
    name="symfony-event-dispatcher",
    content="...",
    tier="framework",
    framework="symfony",
    tags=["symfony", "events", "dispatcher", "subscribers"]
)
```

The KB `framework-symfony` is created automatically if it doesn't exist.

**What to put here:** API reference snippets, hook/event catalogues, service container patterns, configuration reference. Not project-specific code.

### Adding a project KB (Tier 2)

Project KBs are rebuilt from source using `rag_index_project`. You can also add individual docs:

```
rag_add_doc(
    name="my-app-deployment-runbook",
    content="...",
    tier="project",
    project="my-app",
    tags=["deployment", "runbook"]
)
```

**File types indexed by `rag_index_project`:** `.php`, `.twig`, `.yml`, `.yaml`, `.env.example`, `.md`

**Excluded paths:** `vendor/`, `web/core/`, `node_modules/`, `var/`, `dist/`, `build/`, `.git/`

Re-run `rag_index_project` after significant source changes — it clears and rebuilds the KB.

### Adding a common issue (Tier 3)

Use `rag_add_issue` (always goes to `common-issues`):

```
rag_add_issue(
    name="symfony-doctrine-lazy-loading-n-plus-one",
    content="Doctrine's lazy loading triggers an N+1 query when iterating relations. Fix: add JOIN FETCH to the DQL query or use a custom repository method with explicit eager loading. Symptom: query count spikes proportionally to result set size.",
    tags=["symfony", "doctrine", "performance", "n+1", "orm"]
)
```

Call this immediately when you discover a non-obvious bug or fix — don't wait until end of session.

### Adding a devops reference (Tier 4)

```
rag_add_doc(
    name="nginx-upstream-timeouts",
    content="...",
    tier="devops-general",
    tags=["nginx", "proxy", "timeout", "upstream"]
)
```

**What to put here:** Infrastructure patterns that apply across multiple projects — nginx configs, Docker networking, k8s resource limits, SSL cert management, OS-level tuning.

### Adding a custom tier

The four tiers cover most cases, but you can create any KB name and search it directly:

```
# Add to a custom KB
rag_add_doc(name="my-doc", content="...", tier="custom", tags=["custom"])
# This creates/uploads to a KB called "custom"

# Search it directly by passing the KB name in tiers
rag_search(query="...", tiers=["custom"])
```

---

## Search patterns

```bash
# Default: Tiers 1-3, framework+project auto-detected from CWD
rag_search(query="how does the routing system work")

# Infrastructure question — add Tier 4
rag_search(query="docker network bridge mode", tiers=["devops-general", "common-issues"])

# Explicit context when CWD detection is off or wrong
rag_search(query="entity field definition", framework="drupal", project="my-site")

# All tiers
rag_search(query="database connection pooling",
           tiers=["framework", "project", "common-issues", "devops-general"])

# More results
rag_search(query="service container", k=10)
```

Results include a relevance score (0–1). Scores above 0.4 are generally strong matches; below 0.15 suggests the content isn't in the KB yet.

---

## Inspecting KBs

```
rag_list_kbs()
```

Lists all KBs grouped by tier with file counts and internal IDs. Use to confirm indexing worked and to spot stale or orphaned KBs.

The Open WebUI web interface at **http://localhost:3000 → Workspace → Knowledge** provides a visual browser with the same information plus the ability to add/remove files without using the MCP tools.

---

## Session workflow

At the end of a working session:

1. `rag_add_issue` for any bugs or gotchas discovered
2. `rag_add_doc` for architectural decisions, runbooks, or new patterns
3. Write a session summary and upload it to your project KB:

```
rag_add_doc(
    name="sessions--YYYY-MM-DD",
    content="...",
    tier="project",
    project="my-app",
    tags=["session", "summary"]
)
```

---

## Excluded paths

Never pass these to `rag_add_doc` or index them — use Tier 1 for framework internals instead:

- `vendor/` (Composer packages)
- `web/core/` (Drupal core)
- `node_modules/`
- `var/cache/`, `var/log/`
- `dist/`, `build/`

---

## Troubleshooting

**"No knowledge bases matched"** — KB doesn't exist yet. Run `rag_index_project` for project KBs, or `rag_add_doc` to seed framework/devops KBs. Use `rag_list_kbs()` to see what exists.

**Token expired (HTTP 401)** — Rotate in Open WebUI (Settings → Account → API Keys) and update `OPENWEBUI_TOKEN` everywhere it's configured (`.env`, MCP registrations).

**Stale results after re-indexing** — Open WebUI embeds asynchronously. Wait 5–10 seconds after `rag_index_project` before querying.

**Low relevance scores** — The query phrasing may not match how the content was written. Try rephrasing, or add more descriptive text/tags when uploading docs.

**MCP timeout** — Test the server directly:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag_list_kbs","arguments":{}}}' \
  | OPENWEBUI_TOKEN="..." python3 mcp/openwebui-mcp.py
```
