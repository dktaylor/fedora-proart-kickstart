#!/usr/bin/env python3
"""
openwebui-mcp.py — Four-tier MCP stdio server bridging Hermes/Claude to Open WebUI RAG

Tiers:
  1  framework-{name}   PHP framework/CMS reference (Drupal, Symfony, WordPress, CakePHP, Laravel…)
  2  project-{slug}     Per-project source code + project-specific devops/config
  3  common-issues      Cross-cutting gotchas, bugs, non-obvious fixes (all stacks)
  4  devops-general     Infrastructure reference — Docker, k8s, Linux, nginx, OS patterns

Tools:
  rag_search(query, k, tiers, framework, project)
  rag_add_doc(name, content, tier, framework, project, tags)
  rag_add_issue(name, content, tags)
  rag_index_project(path, project)
  rag_list_kbs()

Config via environment:
  OPENWEBUI_URL      base URL (default: http://localhost:3000)
  OPENWEBUI_TOKEN    JWT auth token
  RAG_CWD_DETECT     set to "1" to auto-detect project/framework from CWD (default: 1)

OS context applies to Tier 4 (devops-general) only — search combines tiers naturally.

MCP transport: NDJSON (newline-delimited JSON-RPC 2.0, Hermes v0.16+ format)
"""

import json
import os
import sys
import uuid
import platform
import urllib.request
import urllib.error
from pathlib import Path

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
BASE       = os.environ.get("OPENWEBUI_URL",   "http://localhost:3000")
TOKEN      = os.environ.get("OPENWEBUI_TOKEN", "")
CWD_DETECT = os.environ.get("RAG_CWD_DETECT",  "1") == "1"

# Paths excluded when indexing projects
EXCLUDED_DIRS = {
    "vendor", "var", "node_modules", "core", ".git", ".idea",
    "__pycache__", "dist", "build", "cache", ".cache",
}

# File types indexed from project source
INDEXED_EXTENSIONS = {".php", ".twig", ".yml", ".yaml", ".env.example", ".md"}

# ---------------------------------------------------------------------------
# KB cache — name → id, populated at startup and refreshed on demand
# ---------------------------------------------------------------------------
_KB_CACHE: dict[str, str] = {}


def _refresh_kb_cache() -> None:
    global _KB_CACHE
    try:
        resp = _http("GET", "/api/v1/knowledge/")
        items = resp if isinstance(resp, list) else resp.get("data", resp.get("items", []))
        _KB_CACHE = {item["name"]: item["id"] for item in items if "name" in item and "id" in item}
    except Exception as e:
        print(f"openwebui-mcp: warning: KB cache refresh failed: {e}", file=sys.stderr)


def _ensure_kb(name: str) -> str:
    """Return the KB id for name, creating the KB if it doesn't exist."""
    if name not in _KB_CACHE:
        _refresh_kb_cache()
    if name not in _KB_CACHE:
        result = _http("POST", "/api/v1/knowledge/create", {
            "name": name,
            "description": _kb_description(name),
            "access_control": None,
        })
        _KB_CACHE[name] = result["id"]
    return _KB_CACHE[name]


def _kb_description(name: str) -> str:
    if name.startswith("framework-"):
        fw = name[len("framework-"):]
        return f"Tier 1 — {fw.title()} framework/CMS reference: hooks, APIs, services, patterns"
    if name.startswith("project-"):
        proj = name[len("project-"):]
        return f"Tier 2 — Project '{proj}' source code and project-specific configuration"
    if name == "common-issues":
        return "Tier 3 — Cross-cutting gotchas, bugs, and non-obvious fixes across all stacks"
    if name == "devops-general":
        return "Tier 4 — Infrastructure reference: Docker, k8s, Linux, nginx, SSL, OS patterns"
    return f"RAG knowledge base: {name}"


# ---------------------------------------------------------------------------
# Context detection
# ---------------------------------------------------------------------------
def _detect_context(cwd: str | None = None) -> tuple[str | None, str | None]:
    """Return (project_slug, framework) inferred from the given directory."""
    cwd = cwd or os.getcwd()
    root = Path(cwd)
    project = root.name

    composer = root / "composer.json"
    if composer.exists():
        try:
            data = json.loads(composer.read_text())
            req = {**data.get("require", {}), **data.get("require-dev", {})}
            if "symfony/framework-bundle" in req:
                return project, "symfony"
            if "drupal/core" in req or "drupal/core-recommended" in req:
                return project, "drupal"
            if "cakephp/cakephp" in req:
                return project, "cakephp"
            if "laravel/framework" in req:
                return project, "laravel"
            if "johnpbloch/wordpress" in req or "wordpress" in str(req):
                return project, "wordpress"
        except Exception:
            pass

    if (root / "web" / "core").is_dir() or (root / "core" / "lib" / "Drupal.php").exists():
        return project, "drupal"
    if (root / "wp-config.php").exists() or (root / "wp-content").is_dir():
        return project, "wordpress"

    return project, None


def _detect_os() -> str:
    """Return a short OS identifier for Tier 4 context."""
    system = platform.system()
    if system == "Linux":
        try:
            with open("/etc/os-release") as f:
                for line in f:
                    if line.startswith("ID="):
                        distro = line.strip().split("=")[1].strip('"').lower()
                        return f"linux-{distro}"
        except Exception:
            pass
        return "linux"
    if system == "Darwin":
        return "macos"
    if system == "Windows":
        return "windows"
    return "unknown"


# ---------------------------------------------------------------------------
# Open WebUI HTTP helpers
# ---------------------------------------------------------------------------
def _http(method: str, path: str, data=None, files=None):
    url = f"{BASE}{path}"
    if files:
        boundary = uuid.uuid4().hex
        parts = []
        for field, (fname, content, ctype) in files.items():
            header = (
                f'--{boundary}\r\n'
                f'Content-Disposition: form-data; name="{field}"; filename="{fname}"\r\n'
                f'Content-Type: {ctype}\r\n\r\n'
            ).encode()
            body_part = content if isinstance(content, bytes) else content.encode()
            parts.append(header + body_part + b"\r\n")
        body = b"".join(parts) + f"--{boundary}--\r\n".encode()
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
        raise RuntimeError(f"HTTP {e.code} {method} {path}: {e.read().decode()[:300]}")


def _upload_file(name: str, content: str | bytes, kb_id: str) -> str:
    """Upload a file, replace any existing file with the same name, add to KB."""
    # Remove existing file with this name from the KB
    try:
        existing = _http("GET", "/api/v1/files/")
        items = existing if isinstance(existing, list) else existing.get("items", [])
        for f in items:
            if f.get("meta", {}).get("name") == name:
                fid = f["id"]
                try:
                    _http("POST", f"/api/v1/knowledge/{kb_id}/file/remove", {"file_id": fid})
                    _http("DELETE", f"/api/v1/files/{fid}")
                except Exception:
                    pass
                break
    except Exception:
        pass

    new_file = _http("POST", "/api/v1/files/",
                     files={"file": (name, content, "text/plain")})
    fid = new_file["id"]
    _http("POST", f"/api/v1/knowledge/{kb_id}/file/add", {"file_id": fid})
    return fid


# ---------------------------------------------------------------------------
# Tier / KB resolution
# ---------------------------------------------------------------------------
def _resolve_kb_ids(tiers: list, framework: str | None, project: str | None) -> list[str]:
    """Map tiers + context to concrete KB ids that exist in the cache."""
    ids = []
    for tier in tiers:
        if tier == "framework":
            if framework:
                name = f"framework-{framework}"
                if name in _KB_CACHE:
                    ids.append(_KB_CACHE[name])
            else:
                # search all framework-* KBs
                ids.extend(v for k, v in _KB_CACHE.items() if k.startswith("framework-"))
        elif tier == "project":
            if project:
                name = f"project-{project}"
                if name in _KB_CACHE:
                    ids.append(_KB_CACHE[name])
        elif tier == "common-issues":
            if "common-issues" in _KB_CACHE:
                ids.append(_KB_CACHE["common-issues"])
        elif tier == "devops-general":
            if "devops-general" in _KB_CACHE:
                ids.append(_KB_CACHE["devops-general"])
    # deduplicate, preserve order
    seen = set()
    return [x for x in ids if not (x in seen or seen.add(x))]


# ---------------------------------------------------------------------------
# Tool implementations
# ---------------------------------------------------------------------------

def rag_search(
    query: str,
    k: int = 5,
    tiers: list | None = None,
    framework: str | None = None,
    project: str | None = None,
) -> str:
    if tiers is None:
        tiers = ["framework", "project", "common-issues"]

    if CWD_DETECT:
        det_project, det_framework = _detect_context()
        if framework is None:
            framework = det_framework
        if project is None:
            project = det_project

    _refresh_kb_cache()
    kb_ids = _resolve_kb_ids(tiers, framework, project)

    if not kb_ids:
        avail = ", ".join(sorted(_KB_CACHE)) or "none"
        return (
            f"No knowledge bases matched tiers={tiers} framework={framework} project={project}.\n"
            f"Available KBs: {avail}\n"
            f"Use rag_list_kbs() to see all KBs, or rag_index_project() to create a project KB."
        )

    result = _http("POST", "/api/v1/retrieval/query/collection", {
        "collection_names": kb_ids,
        "query": query,
        "k": k,
    })

    docs      = result.get("documents", [[]])[0]
    metas     = result.get("metadatas", [[]])[0]
    distances = result.get("distances",  [[]])[0]

    if not docs:
        return f"No results for {query!r} across {len(kb_ids)} KB(s)."

    ctx = f"tiers={tiers}, framework={framework or 'any'}, project={project or 'none'}"
    lines = [f"Query: {query!r} [{ctx}]\n"]
    for i, (doc, meta, dist) in enumerate(zip(docs, metas, distances), 1):
        source = meta.get("name", "unknown")
        score  = round(1 - dist, 3)
        lines.append(f"[{i}] {source}  (relevance: {score})\n{doc}\n")
    return "\n---\n".join(lines)


def rag_add_doc(
    name: str,
    content: str,
    tier: str,
    framework: str | None = None,
    project: str | None = None,
    tags: list | None = None,
) -> str:
    tier = tier.strip().lower()

    if tier == "framework":
        if not framework:
            return "Error: 'framework' param required when tier='framework' (e.g. drupal, symfony)"
        kb_name = f"framework-{framework.lower()}"
    elif tier == "project":
        if not project:
            if CWD_DETECT:
                project, _ = _detect_context()
            if not project:
                return "Error: 'project' param required when tier='project'"
        kb_name = f"project-{project.lower()}"
    elif tier == "common-issues":
        kb_name = "common-issues"
    elif tier in ("devops-general", "devops"):
        kb_name = "devops-general"
    else:
        return (
            f"Error: unknown tier '{tier}'. "
            "Valid values: framework, project, common-issues, devops-general"
        )

    if tags:
        header = f"tags: {', '.join(tags)}\n\n"
        content = header + content

    kb_id = _ensure_kb(kb_name)
    _upload_file(name, content, kb_id)
    return f"Uploaded '{name}' → {kb_name} (tier: {tier})."


def rag_add_issue(name: str, content: str, tags: list | None = None) -> str:
    """Add a cross-cutting gotcha or bug fix to Tier 3 common-issues."""
    kb_id = _ensure_kb("common-issues")
    if tags:
        content = f"tags: {', '.join(tags)}\n\n{content}"
    _upload_file(name, content, kb_id)
    tag_str = ", ".join(tags) if tags else "none"
    return f"Added issue '{name}' to common-issues (tags: {tag_str})."


def rag_index_project(path: str | None = None, project: str | None = None) -> str:
    """
    Index a project's source into Tier 2. Auto-detects framework from composer.json
    or directory structure. Clears and rebuilds project-{slug} KB from scratch.
    Excludes vendor/, core/, node_modules/, var/, .git/.
    """
    root = Path(path or os.getcwd()).resolve()
    if not root.is_dir():
        return f"Error: '{root}' is not a directory."

    det_project, framework = _detect_context(str(root))
    slug    = (project or det_project).lower().replace(" ", "-")
    kb_name = f"project-{slug}"

    print(
        f"openwebui-mcp: indexing [{slug}] framework=[{framework or 'generic'}] from {root}",
        file=sys.stderr,
    )

    kb_id = _ensure_kb(kb_name)

    # Clear existing content
    try:
        existing = _http("GET", "/api/v1/files/")
        items = existing if isinstance(existing, list) else existing.get("items", [])
        cleared = 0
        for f in items:
            meta = f.get("meta", {})
            # Match files belonging to this KB by name prefix
            if meta.get("name", "").startswith(f"{slug}--"):
                try:
                    _http("POST", f"/api/v1/knowledge/{kb_id}/file/remove", {"file_id": f["id"]})
                    _http("DELETE", f"/api/v1/files/{f['id']}")
                    cleared += 1
                except Exception:
                    pass
        if cleared:
            print(f"openwebui-mcp: cleared {cleared} existing file(s) from {kb_name}", file=sys.stderr)
    except Exception as e:
        print(f"openwebui-mcp: warning: could not clear KB: {e}", file=sys.stderr)

    # Walk project, upload indexed files
    uploaded = errors = 0
    for fpath in sorted(root.rglob("*")):
        if not fpath.is_file():
            continue
        # Exclude by any path component
        if any(part in EXCLUDED_DIRS for part in fpath.relative_to(root).parts):
            continue
        if fpath.suffix not in INDEXED_EXTENSIONS:
            continue

        rel = fpath.relative_to(root)
        try:
            content = fpath.read_text(encoding="utf-8", errors="replace")
        except Exception:
            continue
        if not content.strip():
            continue

        # Name: project-slug--path--to--file.php
        rag_name = f"{slug}--{str(rel).replace('/', '--')}"
        try:
            _upload_file(rag_name, content, kb_id)
            uploaded += 1
        except Exception as e:
            print(f"openwebui-mcp: skipped {rel}: {e}", file=sys.stderr)
            errors += 1

    result = (
        f"Indexed '{slug}' (framework: {framework or 'generic'}) → {kb_name}\n"
        f"  {uploaded} files uploaded"
        + (f", {errors} errors" if errors else "")
    )
    print(f"openwebui-mcp: {result}", file=sys.stderr)
    return result


def rag_list_kbs() -> str:
    """List all knowledge bases grouped by tier."""
    _refresh_kb_cache()
    if not _KB_CACHE:
        return "No knowledge bases found. Use rag_add_doc() or rag_index_project() to create one."

    tiers: dict[str, list[str]] = {
        "1 — framework":      [],
        "2 — project":        [],
        "3 — common-issues":  [],
        "4 — devops-general": [],
        "other":              [],
    }

    for name in sorted(_KB_CACHE):
        kb_id = _KB_CACHE[name]
        try:
            detail = _http("GET", f"/api/v1/knowledge/{kb_id}")
            files  = detail.get("files") or []
            count  = len(files)
        except Exception:
            count  = "?"

        entry = f"  {name}  ({count} files)  [{kb_id[:8]}...]"
        if name.startswith("framework-"):
            tiers["1 — framework"].append(entry)
        elif name.startswith("project-"):
            tiers["2 — project"].append(entry)
        elif name == "common-issues":
            tiers["3 — common-issues"].append(entry)
        elif name == "devops-general":
            tiers["4 — devops-general"].append(entry)
        else:
            tiers["other"].append(entry)

    lines = [f"{len(_KB_CACHE)} knowledge base(s):"]
    for tier_label, entries in tiers.items():
        if entries:
            lines.append(f"\nTier {tier_label}:")
            lines.extend(entries)
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# MCP tool registry
# ---------------------------------------------------------------------------
TOOLS = [
    {
        "name": "rag_search",
        "description": (
            "Search the RAG knowledge base across one or more tiers. "
            "Call this FIRST before making changes — query for prior decisions, patterns, and fixes. "
            "Auto-detects framework and project from CWD when not specified. "
            "Tiers: 'framework' (Tier 1 — PHP framework/CMS docs), "
            "'project' (Tier 2 — current project code), "
            "'common-issues' (Tier 3 — cross-cutting gotchas), "
            "'devops-general' (Tier 4 — infrastructure + OS patterns)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search query",
                },
                "k": {
                    "type": "integer",
                    "description": "Number of results per KB (default 5)",
                    "default": 5,
                },
                "tiers": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": (
                        "Tiers to search. Default: ['framework','project','common-issues']. "
                        "Add 'devops-general' for infrastructure/OS topics."
                    ),
                    "default": ["framework", "project", "common-issues"],
                },
                "framework": {
                    "type": "string",
                    "description": "Framework filter: drupal, symfony, wordpress, cakephp, laravel. Auto-detected from CWD if omitted.",
                },
                "project": {
                    "type": "string",
                    "description": "Project slug (CWD basename). Auto-detected if omitted.",
                },
            },
            "required": ["query"],
        },
    },
    {
        "name": "rag_add_doc",
        "description": (
            "Add or replace a document in a specific RAG tier. "
            "Use after significant changes to scripts, configs, or session summaries. "
            "Naming convention: NN-category--filename (e.g. '03-scripts--deploy.sh'). "
            "tier='framework' requires framework param. "
            "tier='project' auto-detects project from CWD. "
            "tier='common-issues' for cross-cutting gotchas. "
            "tier='devops-general' for infrastructure reference docs."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name":      {"type": "string", "description": "Filename slug"},
                "content":   {"type": "string", "description": "Document content"},
                "tier":      {"type": "string", "description": "framework | project | common-issues | devops-general"},
                "framework": {"type": "string", "description": "Required when tier=framework"},
                "project":   {"type": "string", "description": "Project slug — defaults to CWD basename"},
                "tags":      {"type": "array", "items": {"type": "string"}, "description": "Optional tags"},
            },
            "required": ["name", "content", "tier"],
        },
    },
    {
        "name": "rag_add_issue",
        "description": (
            "Add a cross-cutting issue, gotcha, or bug fix to Tier 3 (common-issues). "
            "Use immediately after solving something non-obvious — don't wait for session end. "
            "Tag with affected stack, symptom keywords, and OS if relevant to Tier 4."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Short slug, e.g. 'docker-firewalld-zone-conflict'",
                },
                "content": {
                    "type": "string",
                    "description": "Problem description, root cause, and fix",
                },
                "tags": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "e.g. ['docker', 'linux', 'firewalld', 'networking']",
                },
            },
            "required": ["name", "content"],
        },
    },
    {
        "name": "rag_index_project",
        "description": (
            "Index a project's source files into Tier 2 (project-{slug} KB). "
            "Auto-detects framework from composer.json or directory structure. "
            "Clears and rebuilds the KB on each run — always reflects current source. "
            "Excludes vendor/, core/, node_modules/, var/, .git/. "
            "Indexes .php, .twig, .yml, .yaml, .env.example, .md files."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path":    {"type": "string", "description": "Absolute project root path (defaults to CWD)"},
                "project": {"type": "string", "description": "Slug override (defaults to directory name)"},
            },
            "required": [],
        },
    },
    {
        "name": "rag_list_kbs",
        "description": "List all knowledge bases grouped by tier, with file counts.",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
]

TOOL_FNS: dict[str, callable] = {
    "rag_search":        lambda a: rag_search(
                             a["query"],
                             int(a.get("k", 5)),
                             a.get("tiers"),
                             a.get("framework"),
                             a.get("project"),
                         ),
    "rag_add_doc":       lambda a: rag_add_doc(
                             a["name"], a["content"], a["tier"],
                             a.get("framework"), a.get("project"), a.get("tags"),
                         ),
    "rag_add_issue":     lambda a: rag_add_issue(
                             a["name"], a["content"], a.get("tags"),
                         ),
    "rag_index_project": lambda a: rag_index_project(a.get("path"), a.get("project")),
    "rag_list_kbs":      lambda a: rag_list_kbs(),
}

# ---------------------------------------------------------------------------
# MCP stdio transport — NDJSON (one JSON object per line, Hermes v0.16+ format)
# ---------------------------------------------------------------------------

def send(msg: dict) -> None:
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def recv() -> dict | None:
    line = sys.stdin.readline()
    if not line:
        return None
    line = line.strip()
    if not line:
        return None
    return json.loads(line)


def handle(req: dict) -> dict | None:
    rid    = req.get("id")
    method = req.get("method", "")

    if method == "initialize":
        return {
            "jsonrpc": "2.0", "id": rid,
            "result": {
                "protocolVersion": "2025-11-25",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "openwebui-mcp", "version": "2.0.0"},
            },
        }

    if method == "notifications/initialized":
        return None  # notification — no response

    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}}

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

    if rid is not None:
        return {
            "jsonrpc": "2.0", "id": rid,
            "error": {"code": -32601, "message": f"Method not found: {method}"},
        }
    return None


def main() -> None:
    if not TOKEN:
        print("ERROR: OPENWEBUI_TOKEN not set", file=sys.stderr)
        sys.exit(1)

    _refresh_kb_cache()
    os_tag = _detect_os()
    print(
        f"openwebui-mcp v2.0: {BASE} | {len(_KB_CACHE)} KBs loaded | OS={os_tag}",
        file=sys.stderr,
    )

    while True:
        req = recv()
        if req is None:
            break
        resp = handle(req)
        if resp is not None:
            send(resp)


if __name__ == "__main__":
    main()
