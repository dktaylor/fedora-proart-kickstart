# Searching the Knowledge Base Without Code

Both Open WebUI and Qdrant ship with web interfaces that let you browse, search, and manage your knowledge bases entirely from a browser — no API calls, no MCP client needed.

---

## Open WebUI — http://localhost:3000

Open WebUI is the primary interface for working with your knowledge bases. After `docker compose up -d`, navigate to http://localhost:3000 and log in.

### Knowledge base browser

**Workspace → Knowledge** lists every KB grouped by name. From here you can:

- Create a new KB with a name and description
- Upload files (PDF, Markdown, plain text, code) directly into a KB
- Delete or rename KBs
- See how many files each KB contains

### Searching from chat

The most powerful search path is through a chat session:

1. Start a new chat
2. Click the **#** icon (or type `#`) to reference a knowledge base
3. Select one or more KBs — they are now in context for this conversation
4. Ask your question in plain English

The model retrieves relevant chunks from the selected KBs and answers with citations. This is equivalent to calling `rag_search` via the MCP but entirely through the UI.

### Uploading documents

From **Workspace → Knowledge → [select KB] → Add Content**:

- Upload a file — Open WebUI chunks and embeds it automatically
- Paste text directly into the text area
- Files are processed asynchronously; a spinner indicates embedding is in progress

The KB is searchable as soon as embedding completes (typically a few seconds per file).

### Getting your API token

The MCP server authenticates with Open WebUI using a JWT token:

1. Click your avatar (bottom-left) → **Settings → Account**
2. Scroll to **API Keys**
3. Click **Create new secret key**, copy the value
4. Set it as `OPENWEBUI_TOKEN` in your `.env` file or MCP server config

Tokens expire — check the expiry date shown next to the key and rotate before it lapses.

---

## Qdrant Dashboard — http://localhost:6333/dashboard

Qdrant is the vector database backing Open WebUI's retrieval. Its dashboard gives you a low-level view of how your knowledge is actually stored.

> **Note:** The Qdrant dashboard is only available when running the `qdrant` container from `docker-compose.yml`. Open WebUI's default install uses ChromaDB embedded — in that case there is no separate Qdrant dashboard.

### Collections

Navigate to **Collections** to see all vector collections. Each Open WebUI knowledge base corresponds to one Qdrant collection. The collection name is the internal UUID of the KB, not the human-readable name.

For each collection you can see:

| Field | Meaning |
|-------|---------|
| Vectors count | Number of chunks stored (one file → many chunks) |
| Points count | Same as vectors; each "point" is one embedded chunk |
| Status | `green` = ready for queries |
| Vector size | Embedding dimension (depends on the model: 1024 for BGE-large) |
| Distance | Cosine (default for semantic search) |

### Browsing points

Click a collection → **Points** to browse individual chunks. Each point has:

- **ID** — UUID assigned by Open WebUI
- **Vector** — the raw embedding (usually collapsed in the UI)
- **Payload** — metadata: source file name, page number, text content

The payload text is what gets returned to the model during retrieval.

### Running a search from the dashboard

Collections → **[select collection]** → **Search**:

1. Enter a text query in the search box
2. Set **Limit** (number of results, equivalent to `k` in `rag_search`)
3. Click **Search**

Qdrant converts the text to a vector using the configured embedding model and returns the nearest neighbours. This is a useful debugging tool when `rag_search` returns unexpected results — you can see exactly which chunks scored highest and why.

### Understanding the storage layout

```
Qdrant
└── collections/
    ├── <kb-uuid-1>/          ← maps to one Open WebUI KB
    │   └── points/
    │       ├── <chunk-id>    payload: { name, content, source }
    │       ├── <chunk-id>
    │       └── ...
    └── <kb-uuid-2>/
        └── points/
            └── ...
```

Each Open WebUI file upload is split into overlapping chunks (~500 tokens with ~50-token overlap by default). A 10-file KB with ~5,000 tokens per file produces roughly 100–200 Qdrant points per collection.

### Qdrant REST API (optional)

If you prefer curl over the UI:

```bash
# List all collections
curl http://localhost:6333/collections

# Count points in a collection
curl http://localhost:6333/collections/<uuid>/points/count

# Search a collection directly
curl -X POST http://localhost:6333/collections/<uuid>/points/search \
  -H "Content-Type: application/json" \
  -d '{"vector": [...], "limit": 5, "with_payload": true}'
```

The full API reference is at http://localhost:6333/dashboard#/api (Swagger UI embedded in the dashboard).
