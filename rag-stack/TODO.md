# TODO

## MCP server

### Proactive synthesis tool (`rag_synthesize`)

Add a tool that chains `rag_search` across multiple tiers, combines the retrieved
chunks into a single context window, and passes them to the connected LLM to produce
a synthesised summary rather than raw retrieval results.

Use cases:
- "Summarise everything we know about X across all tiers"
- "What do we know about this error message?" (searches common-issues + project + devops)
- "Give me a briefing on this project before I start work" (project KB + recent sessions)
- Onboarding a new developer — pull framework conventions, project patterns, and known issues in one shot

Design notes:
- Accept `query`, `tiers`, `k`, and a `synthesize=True` flag (or separate tool name)
- Collect results from each tier separately, preserving source labels
- Build a structured prompt: retrieved chunks with tier/source headers, then ask the
  model to synthesise into a coherent answer
- Return both the synthesis and the raw sources so the caller can cite them
- The LLM doing the synthesis is whichever model the MCP client is connected to —
  no separate model config needed in the MCP server itself

Related: `rag_search` already returns raw chunks with relevance scores; synthesis
is purely a prompt-engineering layer on top of the existing retrieval pipeline.

---

## Infrastructure

### Phase 1 — Qdrant migration

Open WebUI currently ships with ChromaDB embedded. Switching to the Qdrant container
in `docker-compose.yml` requires:
- Setting `VECTOR_DB=qdrant` and `QDRANT_URI` in Open WebUI env (already in compose)
- Re-uploading all existing KB content after migration (ChromaDB and Qdrant use
  separate storage; content does not carry over automatically)
- Verifying embedding dimensions match between old and new backends

### Phase 2 — Seed Tier 1 framework KBs

Populate `framework-{name}` KBs with reference material for each supported framework.
Priority order: Symfony, Drupal, WordPress, CakePHP, Laravel.

Sources to consider: official docs snapshots, hook/event catalogues, service container
reference, common configuration patterns.

### Phase 4 — Project indexer improvements

`rag_index_project` currently indexes whole files. Improvements:
- Chunk large files (>500 lines) with overlap before upload so retrieval is more precise
- Add `.js`, `.ts`, `.json` to indexed extensions for JS-heavy projects
- Support a per-project `.ragignore` file to exclude paths beyond the global defaults
- Progress reporting for large codebases

### Phase 5 — Hermes session hooks

Wire up automatic RAG actions at session boundaries:
- `on_session_start`: call `rag_search` with a project briefing query and inject
  results into the system prompt
- `on_session_end`: prompt the agent to save discoveries via `rag_add_issue` /
  `rag_add_doc` before context is lost
