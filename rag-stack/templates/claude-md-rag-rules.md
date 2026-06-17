## RAG Integration Rules

The project uses a four-tier RAG system via Open WebUI. MCP tools are available:
`rag_search`, `rag_add_doc`, `rag_add_issue`, `rag_index_project`, `rag_list_kbs`.

### Four-tier knowledge structure

| Tier | KB name | Contains |
|------|---------|---------|
| 1 | `framework-{name}` | Framework/CMS reference — hooks, APIs, services, patterns |
| 2 | `project-{slug}` | Per-project source code + project-specific devops/config |
| 3 | `common-issues` | Cross-cutting gotchas, bugs, non-obvious fixes (all stacks) |
| 4 | `devops-general` | Infrastructure reference — Docker, k8s, Linux, nginx, SSL |

This project's code lives in `project-{slug}` (Tier 2). Replace `{slug}` with the
directory basename of this repository.

### Excluded paths — never read directly

Do not read or analyze these paths. Use `rag_search(tier="framework")` instead:
- `vendor/`
- `web/core/`
- `node_modules/`
- `var/cache/`

### Rules

- **Search RAG first** before any coding task: `rag_search(query, framework=<detected>, project=<detected>)`
- **Default tiers**: `["framework", "project", "common-issues"]` — add `"devops-general"` for infrastructure topics
- **After solving something non-obvious**: call `rag_add_issue()` immediately with tags
- **After significant file changes**: call `rag_add_doc(tier="project")` with a descriptive name
- **Session summaries**: generate and upload via `rag_add_doc(tier="project")` at session end

### Web interfaces

- Open WebUI KB browser: http://localhost:3000 → Workspace → Knowledge
- Qdrant dashboard: http://localhost:6333/dashboard
