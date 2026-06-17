# openwebui-rag-mcp

A four-tier RAG system built on [Open WebUI](https://github.com/open-webui/open-webui) and [Qdrant](https://qdrant.tech/), with an MCP server that bridges AI clients (Claude Code, Hermes, Cursor) to the knowledge base.

## Architecture

```
AI client (Claude Code / Hermes / Cursor)
    │  MCP (stdio)
    ▼
openwebui-mcp.py          ← five tools: rag_search, rag_add_doc,
    │                                    rag_add_issue, rag_index_project,
    │  HTTP / REST                       rag_list_kbs
    ▼
Open WebUI  :3000         ← web UI + embedding + retrieval API
    │
    ▼
Qdrant      :6333         ← vector storage + similarity search
```

### Four tiers

| Tier | KB name | Contents |
|------|---------|----------|
| 1 | `framework-{name}` | Framework/CMS reference — Drupal, Symfony, WordPress, CakePHP, Laravel |
| 2 | `project-{slug}` | Per-project source code + project-specific config |
| 3 | `common-issues` | Cross-cutting bugs, gotchas, non-obvious fixes |
| 4 | `devops-general` | Infrastructure — Docker, k8s, Linux, nginx, SSL |

## Let Claude Code set this up for you

Open a Claude Code session in the directory where you've cloned this repo and paste the following prompt. Claude will walk through every step interactively — starting the stack, getting your token, registering the MCP server, and indexing your first project.

```
I want to set up the openwebui-rag-mcp four-tier RAG stack in this directory.
The repo contains: docker-compose.yml (Open WebUI + Qdrant), mcp/openwebui-mcp.py
(the MCP server), .env.example, and docs/ with setup guides.

Please do the following in order:
1. Copy .env.example to .env and ask me for my OLLAMA_BASE_URL if Ollama isn't
   running on localhost:11434.
2. Run `docker compose up -d` and confirm both containers are healthy.
3. Tell me to open http://localhost:3000, create an account, and generate an API
   token at Settings → Account → API Keys. Wait for me to paste the token back.
4. Write the token into .env as OPENWEBUI_TOKEN.
5. Register the MCP server with Claude Code at user scope using `claude mcp add`,
   substituting the absolute path to mcp/openwebui-mcp.py and the token from .env.
6. Verify the MCP server is connected with `claude mcp list`.
7. Ask me which project I want to index first, then call rag_index_project() with
   that path.
8. Run rag_list_kbs() to confirm the project KB was created.
9. Show me the web interface URLs and confirm everything is working.
```

## Quick start

```bash
# 1. Configure
cp .env.example .env
# Edit .env — set OLLAMA_BASE_URL if Ollama isn't on localhost

# 2. Start Open WebUI + Qdrant
docker compose up -d

# 3. Get API token
# Open http://localhost:3000 → Settings → Account → API Keys → Create
# Paste the token into .env as OPENWEBUI_TOKEN

# 4. Register the MCP server with your AI client
# Claude Code:
claude mcp add -s user openwebui-rag \
  -e OPENWEBUI_URL=http://localhost:3000 \
  -e OPENWEBUI_TOKEN="<token>" \
  -e RAG_CWD_DETECT=1 \
  -- python3 /path/to/rag-stack/mcp/openwebui-mcp.py

# 5. Index a project (run from the project root)
# rag_index_project()
```

## Web interfaces

| Interface | URL | Purpose |
|-----------|-----|---------|
| Open WebUI | http://localhost:3000 | Chat, KB browser, file upload |
| Open WebUI Knowledge | http://localhost:3000 (Workspace → Knowledge) | Browse/search KBs without code |
| Qdrant Dashboard | http://localhost:6333/dashboard | Vector DB browser, collection stats, point search |
| Qdrant Swagger | http://localhost:6333/dashboard#/api | REST API reference |

See `docs/webui-guide.md` for a full walkthrough of both interfaces.

## MCP tools

| Tool | What it does |
|------|-------------|
| `rag_search` | Search across tiers; auto-detects project+framework from CWD |
| `rag_add_doc` | Upload/replace a doc in any tier KB |
| `rag_add_issue` | Add a cross-cutting bug or fix to `common-issues` |
| `rag_index_project` | Clear and rebuild a project KB from source files |
| `rag_list_kbs` | List all KBs grouped by tier with file counts |

## Templates

| File | Use for |
|------|---------|
| `templates/cursor-mcp.json` | Copy to `.cursor/mcp.json` in each project |
| `templates/claude-md-rag-rules.md` | Paste into project `CLAUDE.md` |
| `templates/hermes-mcp-config.yaml` | Add to `~/.hermes/config.yaml` |

## Docs

- `docs/usage.md` — four-tier guide: getting started, adding content, search patterns, session workflow
- `docs/webui-guide.md` — using Open WebUI and Qdrant dashboard without writing code
