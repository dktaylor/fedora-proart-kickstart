#!/usr/bin/env python3
"""
openwebui-mcp.py — MCP stdio server bridging Hermes to Open WebUI RAG

Exposes three tools:
  rag_search(query, k=5)      — semantic search against the knowledge base
  rag_upsert(name, content)   — upload/replace a file in the collection
  rag_list()                  — list all files in the collection

Configuration via environment variables (set in Hermes mcp_servers config):
  OPENWEBUI_URL    — base URL, default http://localhost:3000
  OPENWEBUI_TOKEN  — JWT auth token
  OPENWEBUI_KB_ID  — knowledge base UUID

MCP stdio transport: Content-Length framed JSON-RPC 2.0 (LSP-style).
"""

import json
import os
import sys
import uuid
import urllib.request
import urllib.error

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
BASE  = os.environ.get("OPENWEBUI_URL",   "http://localhost:3000")
TOKEN = os.environ.get("OPENWEBUI_TOKEN", "")
KB_ID = os.environ.get("OPENWEBUI_KB_ID", "")

# ---------------------------------------------------------------------------
# Open WebUI API helpers
# ---------------------------------------------------------------------------

def _headers(extra=None):
    h = {"Authorization": f"Bearer {TOKEN}"}
    if extra:
        h.update(extra)
    return h

def _http(method, path, data=None, files=None):
    url = f"{BASE}{path}"
    if files:
        boundary = uuid.uuid4().hex
        parts = []
        for name, (fname, content, ctype) in files.items():
            parts.append(
                f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; '
                f'filename="{fname}"\r\nContent-Type: {ctype}\r\n\r\n'.encode()
                + (content if isinstance(content, bytes) else content.encode())
                + b'\r\n'
            )
        body = b''.join(parts) + f'--{boundary}--\r\n'.encode()
        req = urllib.request.Request(url, data=body, method=method)
        req.add_header("Authorization", f"Bearer {TOKEN}")
        req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    elif data is not None:
        body = json.dumps(data).encode()
        req = urllib.request.Request(url, data=body, method=method)
        req.add_header("Authorization", f"Bearer {TOKEN}")
        req.add_header("Content-Type", "application/json")
    else:
        req = urllib.request.Request(url, method=method)
        req.add_header("Authorization", f"Bearer {TOKEN}")
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code}: {e.read().decode()[:200]}")

# ---------------------------------------------------------------------------
# Tool implementations
# ---------------------------------------------------------------------------

def rag_search(query: str, k: int = 5) -> str:
    """Semantic search against the Open WebUI knowledge base."""
    result = _http("POST", "/api/v1/retrieval/query/collection", {
        "collection_names": [KB_ID],
        "query": query,
        "k": k,
    })
    docs      = result.get("documents", [[]])[0]
    metas     = result.get("metadatas", [[]])[0]
    distances = result.get("distances", [[]])[0]

    if not docs:
        return "No results found."

    lines = []
    for i, (doc, meta, dist) in enumerate(zip(docs, metas, distances), 1):
        source = meta.get("name", "unknown")
        score  = round(1 - dist, 3)  # convert distance to similarity
        lines.append(f"[{i}] {source} (relevance: {score})\n{doc}\n")
    return "\n---\n".join(lines)


def rag_list() -> str:
    """List all files in the knowledge base."""
    resp  = _http("GET", "/api/v1/files/")
    items = resp.get("items", [])
    kb_files = [
        f for f in items
        if f.get("meta", {}).get("collection_name") == KB_ID
        or f.get("meta", {}).get("data", {}) == {}  # fallback: include all
    ]
    if not kb_files:
        return "Knowledge base is empty."
    lines = [f"  {f['meta']['name']}  ({f['meta'].get('size', '?')} bytes)"
             for f in sorted(kb_files, key=lambda x: x["meta"]["name"])]
    return f"{len(kb_files)} files in knowledge base:\n" + "\n".join(lines)


def rag_upsert(name: str, content: str) -> str:
    """Upload or replace a file in the knowledge base."""
    # Remove existing file with this name if present
    resp  = _http("GET", "/api/v1/files/")
    items = resp.get("items", [])
    for f in items:
        if f["meta"]["name"] == name:
            _http("POST", f"/api/v1/knowledge/{KB_ID}/file/remove", {"file_id": f["id"]})
            _http("DELETE", f"/api/v1/files/{f['id']}")
            break

    # Upload new file
    new_id = _http("POST", "/api/v1/files/",
                   files={"file": (name, content.encode(), "text/plain")})["id"]
    _http("POST", f"/api/v1/knowledge/{KB_ID}/file/add", {"file_id": new_id})
    return f"Uploaded '{name}' to knowledge base (id: {new_id[:8]}...)."

# ---------------------------------------------------------------------------
# MCP tool registry
# ---------------------------------------------------------------------------

TOOLS = [
    {
        "name": "rag_search",
        "description": (
            "Semantic search against the fedora-proart-kickstart RAG knowledge base. "
            "Use this FIRST before making changes — query for prior decisions, fixes, "
            "and existing context on the topic."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search query"},
                "k":     {"type": "integer", "description": "Number of results (default 5)", "default": 5},
            },
            "required": ["query"],
        },
    },
    {
        "name": "rag_list",
        "description": "List all files currently in the fedora-proart-kickstart knowledge base.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "required": [],
        },
    },
    {
        "name": "rag_upsert",
        "description": (
            "Upload or replace a file in the fedora-proart-kickstart knowledge base. "
            "Use after significant changes: naming convention is NN-category--filename "
            "(e.g. '03-scripts--verify.sh', '01-sessions--2026-06-14-summary.md')."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name":    {"type": "string", "description": "RAG filename (NN-category--filename)"},
                "content": {"type": "string", "description": "File content to upload"},
            },
            "required": ["name", "content"],
        },
    },
]

TOOL_FNS = {
    "rag_search": lambda args: rag_search(args["query"], int(args.get("k", 5))),
    "rag_list":   lambda args: rag_list(),
    "rag_upsert": lambda args: rag_upsert(args["name"], args["content"]),
}

# ---------------------------------------------------------------------------
# MCP stdio transport (Content-Length framed JSON-RPC 2.0)
# ---------------------------------------------------------------------------

def send(msg: dict):
    body = json.dumps(msg).encode()
    sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    sys.stdout.buffer.flush()


def recv() -> dict | None:
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        line = line.rstrip(b"\r\n")
        if not line:
            break
        if b":" in line:
            k, v = line.split(b":", 1)
            headers[k.strip().lower()] = v.strip()
    length = int(headers.get(b"content-length", 0))
    if not length:
        return None
    return json.loads(sys.stdin.buffer.read(length))


def handle(req: dict) -> dict | None:
    rid    = req.get("id")
    method = req.get("method", "")

    if method == "initialize":
        return {
            "jsonrpc": "2.0", "id": rid,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "openwebui-mcp", "version": "1.0.0"},
            },
        }

    if method == "notifications/initialized":
        return None  # no response for notifications

    if method == "tools/list":
        return {
            "jsonrpc": "2.0", "id": rid,
            "result": {"tools": TOOLS},
        }

    if method == "tools/call":
        name = req["params"]["name"]
        args = req["params"].get("arguments", {})
        if name not in TOOL_FNS:
            return {
                "jsonrpc": "2.0", "id": rid,
                "error": {"code": -32601, "message": f"Unknown tool: {name}"},
            }
        try:
            text = TOOL_FNS[name](args)
            return {
                "jsonrpc": "2.0", "id": rid,
                "result": {"content": [{"type": "text", "text": text}]},
            }
        except Exception as e:
            return {
                "jsonrpc": "2.0", "id": rid,
                "result": {
                    "content": [{"type": "text", "text": f"Error: {e}"}],
                    "isError": True,
                },
            }

    # Unknown method
    if rid is not None:
        return {
            "jsonrpc": "2.0", "id": rid,
            "error": {"code": -32601, "message": f"Method not found: {method}"},
        }
    return None


def main():
    if not TOKEN:
        print("ERROR: OPENWEBUI_TOKEN not set", file=sys.stderr)
        sys.exit(1)
    if not KB_ID:
        print("ERROR: OPENWEBUI_KB_ID not set", file=sys.stderr)
        sys.exit(1)

    print(f"openwebui-mcp: connected to {BASE}, KB={KB_ID[:8]}...", file=sys.stderr)

    while True:
        req = recv()
        if req is None:
            break
        resp = handle(req)
        if resp is not None:
            send(resp)


if __name__ == "__main__":
    main()
