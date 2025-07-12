"""
Workspace keyword library for interacting with RunWhen Workspace resources.

Scope: GLOBAL
"""

# ──────────────────────────────────────────────────────────────────────────────
# Imports
# ──────────────────────────────────────────────────────────────────────────────
import os
import re
import json
import time
import logging
import requests
from datetime import datetime
from typing import Any, Dict, List, Tuple, Optional
from robot.libraries.BuiltIn import BuiltIn

from RW import platform                      
from RW.Core import Core                     

# ──────────────────────────────────────────────────────────────────────────────
# Logging guarantees  – creates both Robot and Python loggers safely.
# ──────────────────────────────────────────────────────────────────────────────
try:
    from robot.api import logger as robot_logger
except ImportError:
    # When Robot logger is unavailable, fall back to standard logging
    robot_logger = logging.getLogger("robot_fallback")

# Determine a stable Python logger for platform-level logs
_plat = getattr(platform, "logger", None)
if _plat and hasattr(_plat, "warning") and hasattr(_plat, "exception"):
    platform_logger = _plat
else:
    platform_logger = logging.getLogger("workspace_utils")

# Uniform WARNING helper

def warning_log(msg: str, *details: Any) -> None:
    try:
        robot_logger.warn(msg)
    except AttributeError:
        robot_logger.info(f"WARNING: {msg}")

    # stringify every detail first
    text = " | ".join(json.dumps(d) if isinstance(d, (dict, list)) else str(d)
                      for d in details)

    platform_logger.warning("%s – %s", msg, text)

# ──────────────────────────────────────────────────────────────────────────────
# Module-level constants
# ──────────────────────────────────────────────────────────────────────────────
ROBOT_LIBRARY_SCOPE = "GLOBAL"

SHELL_HISTORY: List[str] = []
SECRET_PREFIX: str = "secret__"
SECRET_FILE_PREFIX: str = "secret_file__"


# ===========================================================================
# Internal paginator
# ===========================================================================

def _page_through_slxs(start_url: str, session: requests.Session) -> List[Dict]:
    """Internal: generic paginator compatible with both `next` and `page` meta."""
    url = start_url
    collected: List[Dict] = []

    while url:
        resp = session.get(url, timeout=10)
        resp.raise_for_status()
        body = resp.json()

        collected.extend(body.get("results", []))

        # style A – SmartLink pagination
        url = body.get("next")

        # style B – offset/limit
        if url is None and "page" in body:
            p = body["page"]
            ret = len(body.get("results", []))
            total = p.get("total", ret)
            off = p.get("offset", 0) + ret
            if off < total:
                url = re.sub(r"offset=\d+", f"offset={off}", resp.url)

    return collected


# ===========================================================================
# SLX-related helpers
# ===========================================================================

def get_slxs_with_tag(tag_list: List[Any]) -> List[Dict]:
    """
    Return all SLXs whose *spec.tags* contain at least one tag in *tag_list*.

    `tag_list` may contain either
      • {"name": "...", "value": "..."} dictionaries
      • "name:value" strings

    Matching is case-insensitive on both name and value.
    """
    try:
        ws = import_platform_variable("RW_WORKSPACE")
        root = import_platform_variable("RW_WORKSPACE_API_URL")
    except ImportError:
        return []

    wanted: set[Tuple[str, str]] = set()
    for item in tag_list:
        if isinstance(item, dict):
            name, val = item.get("name"), item.get("value")
        elif isinstance(item, str) and ":" in item:
            name, val = item.split(":", 1)
        else:
            continue
        wanted.add((name.strip().lower(), val.strip().lower()))
    if not wanted:
        return []

    sess = platform.get_authenticated_session()
    start_url = f"{root}/{ws}/slxs?limit=500"
    try:
        all_slxs = _page_through_slxs(start_url, sess)
    except (requests.RequestException, json.JSONDecodeError) as e:
        warning_log("Fetching SLXs failed", str(e))
        return []

    matches: List[Dict] = []
    for slx in all_slxs:
        for tag in slx.get("spec", {}).get("tags", []):
            pair = (
                str(tag.get("name", "")).strip().lower(),
                str(tag.get("value", "")).strip().lower(),
            )
            if pair in wanted:
                matches.append(slx)
                break
    return matches


def get_slxs_with_entity_reference(entity_refs: List[str]) -> List[Dict]:
    """
    Return all SLXs that reference (alias, tag, configProvided, additionalContext)
    any identifier in *entity_refs* (case-insensitive substring match).
    """
    try:
        ws = import_platform_variable("RW_WORKSPACE")
        root = import_platform_variable("RW_WORKSPACE_API_URL")
    except ImportError:
        return []

    token = os.getenv("RW_USER_TOKEN")
    if token:
        sess = requests.Session()
        sess.headers.update({
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        })
    else:
        sess = platform.get_authenticated_session()

    start_url = f"{root}/{ws}/slxs?limit=500"
    try:
        all_slxs = _page_through_slxs(start_url, sess)
    except (requests.RequestException, json.JSONDecodeError) as e:
        warning_log("Paging SLXs failed", str(e))
        return []

    terms = {t.lower() for t in entity_refs if isinstance(t, str) and t}
    hits: List[Dict] = []

    for slx in all_slxs:
        spec = slx.get("spec", {})
        corpus = [spec.get("alias", "")]

        for t in spec.get("tags", []):
            n, v = t.get("name", ""), t.get("value", "")
            corpus.extend([n, v, f"{n}:{v}"])

        for cp in spec.get("configProvided", []):
            n, v = cp.get("name", ""), cp.get("value", "")
            corpus.extend([n, v, f"{n}:{v}"])

        for k, v in spec.get("additionalContext", {}).items():
            corpus.extend([k, str(v), f"{k}:{v}"])

        joined = " ".join(corpus).lower()
        if any(term in joined for term in terms):
            hits.append(slx)

    return hits


def run_tasks_for_slx(slx: str) -> Optional[Dict]:
    """Create a runRequest containing all tasks in the SLX runbook."""
    try:
        runsess = import_platform_variable("RW_SESSION_ID")
        ws = import_platform_variable("RW_WORKSPACE")
        root = import_platform_variable("RW_WORKSPACE_API_URL")
    except ImportError:
        return None

    sess = platform.get_authenticated_session()

    rb_url = f"{root}/{ws}/slxs/{slx}/runbook"
    try:
        rb = sess.get(rb_url, timeout=10)
        rb.raise_for_status()
        tasks = rb.json().get("status", {}).get("codeBundle", {}).get("tasks", [])
    except (requests.RequestException, json.JSONDecodeError) as e:
        warning_log("Runbook fetch failed", str(e))
        tasks = []

    patch_body = {
        "runRequests": [{
            "slxName": f"{ws}--{slx}",
            "taskTitles": tasks
        }]
    }
    rs_url = f"{root}/{ws}/runsessions/{runsess}"
    try:
        rsp = sess.patch(rs_url, json=patch_body, timeout=10)
        rsp.raise_for_status()
        return rsp.json()
    except (requests.RequestException, json.JSONDecodeError) as e:
        warning_log("RunSession patch failed", str(e))
        return None


# ===========================================================================
# Platform variable + import helpers
# ===========================================================================

def import_platform_variable(varname: str) -> str:
    """Return the value of a RunWhen platform-provided var or raise ImportError."""
    if not varname.startswith("RW_"):
        raise ValueError(f"{varname!r} is not a platform variable")
    value = os.getenv(varname)
    if not value:
        raise ImportError(f"{varname} is unset")
    return value


def import_runsession_details(runsession_id: Optional[str] = None) -> Optional[str]:
    """
    Fetch full RunSession details as JSON string. Uses RW_USER_TOKEN if set.
    """
    try:
        if not runsession_id:
            runsession_id = import_platform_variable("RW_SESSION_ID")
        ws = import_platform_variable("RW_WORKSPACE")
        root = import_platform_variable("RW_WORKSPACE_API_URL")
    except ImportError:
        BuiltIn().log("Missing required vars for import_runsession_details", level="WARN")
        return None

    url = f"{root}/{ws}/runsessions/{runsession_id}"
    BuiltIn().log(f"Fetching RunSession: {url}", level="INFO")

    token = os.getenv("RW_USER_TOKEN")
    if token:
        sess = requests.Session()
        sess.headers.update({"Authorization": f"Bearer {token}"})
    else:
        sess = platform.get_authenticated_session()

    try:
        rsp = sess.get(url, timeout=10, verify=platform.REQUEST_VERIFY)
        rsp.raise_for_status()
        return json.dumps(rsp.json())
    except (requests.RequestException, json.JSONDecodeError) as e:
        warning_log("Import RunSession details failed", str(e))
        return None


def import_memo_variable(key: str) -> Optional[str]:
    """
    Retrieve a memo value by key from the current runsession's runRequests.
    Returns JSON string or None.
    """
    try:
        runreq = str(import_platform_variable("RW_RUNREQUEST_ID"))
        runsess = import_platform_variable("RW_SESSION_ID")
        ws = import_platform_variable("RW_WORKSPACE")
        root = import_platform_variable("RW_WORKSPACE_API_URL")
    except ImportError:
        BuiltIn().log("Missing vars for import_memo_variable", level="WARN")
        return None

    url = f"{root}/{ws}/runsessions/{runsess}"
    BuiltIn().log(f"Fetching memos: {url}", level="INFO")
    sess = platform.get_authenticated_session()

    try:
        rsp = sess.get(url, timeout=10, verify=platform.REQUEST_VERIFY)
        rsp.raise_for_status()
        for rr in rsp.json().get("runRequests", []):
            if str(rr.get("id")) == runreq:
                for memo in rr.get("memo", []):
                    if isinstance(memo, dict) and key in memo:
                        val = memo[key]
                        try:
                            return json.dumps(val)
                        except (TypeError, ValueError):
                            return json.dumps(str(val))
        return json.dumps(None)
    except (requests.RequestException, json.JSONDecodeError) as e:
        warning_log("Fetching memo failed", str(e))
        return None


def import_related_runsession_details(
    json_string: str,
    api_token: Optional[platform.Secret] = None,
    poll_interval: float = 5.0,
    max_wait_seconds: float = 300.0,
) -> Optional[str]:
    """
    Parse 'runsessionId' from notes and poll until runRequests stable.
    Returns JSON string of final runsession or None.
    """
    try:
        data = json.loads(json_string)
        notes = json.loads(data.get("notes", "{}"))
        runsession_id = notes.get("runsessionId")
        if not runsession_id:
            BuiltIn().log("No runsessionId in notes", level="WARN")
            return None
    except json.JSONDecodeError:
        BuiltIn().log("Bad JSON in import_related_runsession_details", level="WARN")
        return None

    try:
        ws = import_platform_variable("RW_WORKSPACE")
        root = import_platform_variable("RW_WORKSPACE_API_URL")
    except ImportError as e:
        BuiltIn().log(f"Missing vars: {e}", level="WARN")
        return None

    endpoint = f"{root}/{ws}/runsessions/{runsession_id}"
    BuiltIn().log(f"Polling: {endpoint}", level="INFO")

    # choose session
    if api_token:
        sess = requests.Session()
        sess.headers.update({"Authorization": f"Bearer {api_token.value}"})
    else:
        token = os.getenv("RW_USER_TOKEN")
        if token:
            sess = requests.Session()
            sess.headers.update({"Authorization": f"Bearer {token}"})
        else:
            sess = platform.get_authenticated_session()

    stable = 0
    last_len = None
    start = time.time()

    while True:
        try:
            rsp = sess.get(endpoint, timeout=10, verify=platform.REQUEST_VERIFY)
            rsp.raise_for_status()
            sd = rsp.json()
        except (requests.RequestException, json.JSONDecodeError) as e:
            BuiltIn().log(f"Polling error: {e}", level="WARN")
            return None

        rr = sd.get("runRequests", [])
        curr = len(rr)
        if last_len is not None and curr == last_len:
            stable += 1
        else:
            stable = 0
        last_len = curr

        if stable >= 3:
            return json.dumps(sd)

        if time.time() - start > max_wait_seconds:
            raise TimeoutError(f"Timeout waiting for runsession {runsession_id}")

        time.sleep(poll_interval)

def get_workspace_config() -> list | dict:
    """
    Return workspace.yaml (already rendered to JSON by the Workspace-API).

    The function behaves correctly both:
      • inside the RunWhen runtime – where `platform.get_authenticated_session()`
        already carries the service-mesh auth headers, and
      • during local / unit testing – where you may export RW_USER_TOKEN to
        override the auth header.

    Falls back to an empty list on any failure.
    """
    # ── 0. Resolve workspace + API root ─────────────────────────────────────
    try:
        ws   = import_platform_variable("RW_WORKSPACE")
        root = import_platform_variable("RW_WORKSPACE_API_URL")
    except ImportError:
        return []          # running outside expected context

    url = f"{root.rstrip('/')}/{ws}/branches/main/workspace.yaml?format=json"

    # ── 1. Build an authenticated session ──────────────────────────────────
    sess = platform.get_authenticated_session()      # carries default auth

    user_token = os.getenv("RW_USER_TOKEN")
    if user_token:
        # Local test override
        sess.headers.update({"Authorization": f"Bearer {user_token}"})

    sess.headers.setdefault("Content-Type", "application/json")

    # ── 2. Fetch & return the file ─────────────────────────────────────────
    try:
        resp = sess.get(url, timeout=10)
        resp.raise_for_status()
        # API shape: { "asJson": { …workspace.yaml parsed… } }
        return resp.json().get("asJson", [])
    except (requests.RequestException, json.JSONDecodeError) as e:
        BuiltIn().log(
            f"[get_workspace_config] Failed fetching workspace.yaml for '{ws}': {e}",
            level="WARN",
        )
        platform_logger.exception(e)
        return []


def get_nearby_slxs(workspace_config: dict, slx_name: str) -> list:
    """
    Given a RunWhen workspace config (in dictionary form) and the short name
    of a specific SLX (e.g. "rc-ob-grnsucsc1c-redis-health-a7c33f4e"),
    return all SLXs in the same slxGroup.

    :param workspace_config: Dict representing workspace.yaml as JSON.
    :param slx_name: The SLX short name to look for.
    :return: A list of SLX short names in the same slxGroup as `slx_name`.
             If no group is found containing `slx_name`, returns an empty list.
    """
    # Navigate to the "slxGroups" array under "spec".
    slx_groups = workspace_config.get("spec", {}).get("slxGroups", [])

    for group in slx_groups:
        slxs = group.get("slxs", [])
        if slx_name in slxs:
            # Return the entire list of slxs in this group.
            return slxs

    # If we don't find the slx in any group, return an empty list.
    return []

def get_workspace_slxs(
    rw_api_url: str,
    api_token: platform.Secret,
    rw_workspace: str,
) -> str:
    """
    Get all SLXs in a workspace (paginated) and return combined JSON string.
    """
    url = f"{rw_api_url}/workspaces/{rw_workspace}/slxs?limit=500"
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_token.value}",
    }
    all_results = []
    total = None

    while url:
        resp = requests.get(url, headers=headers, timeout=10)
        resp.raise_for_status()
        p = resp.json()
        total = p.get("count", len(all_results))
        all_results.extend(p.get("results", []))
        url = p.get("next")

    combined = {
        "count": total,
        "next": None,
        "previous": None,
        "results": all_results,
    }
    return json.dumps(combined)


# ===========================================================================
# Task-search and report helpers
# ===========================================================================

def _post_json(session: requests.Session, url: str, payload: dict) -> dict:
    resp = session.post(url, json=payload, timeout=10, verify=platform.REQUEST_VERIFY)

    if resp.status_code >= 400:
        curl_cmd = _as_curl(
            "POST",
            url,
            session,
            json_body=payload,
            timeout=10,
            verify=platform.REQUEST_VERIFY,
        )
        warning_log(
            f"POST {url} → {resp.status_code}",
            f"cURL: {curl_cmd}",
            f"Response: {resp.text[:500]}",
        )

    resp.raise_for_status()
    return resp.json()

# ─────────────────────────────────────────────────────────────
# Helper: build a cURL command from a requests session
# ─────────────────────────────────────────────────────────────
def _as_curl(
    method: str,
    url: str,
    sess: requests.Session,
    json_body: dict | None = None,
    timeout: int | float | None = None,
    verify: bool = True,
) -> str:
    """
    Return a one-liner cURL command equivalent to the request.
    Secrets in the Authorization header are redacted.
    """
    parts: list[str] = [f"curl -X {method.upper()}"]

    # time-outs / TLS verify
    if timeout:
        parts.append(f"--max-time {timeout}")
    if not verify:
        parts.append("-k")          # --insecure

    # headers (session-level + requests default)
    hdrs = requests.utils.default_headers()
    hdrs.update(sess.headers or {})
    for k, v in hdrs.items():
        if k.lower() == "authorization":
            v = v[:12] + "...REDACTED"
        parts.append(f"-H '{k}: {v}'")

    # body
    if json_body is not None:
        parts.append(f"--data-raw '{json.dumps(json_body, separators=(',', ':'))}'")

    parts.append(f"'{url}'")
    return " ".join(parts)

def perform_task_search_with_persona(
    query: str,
    persona: str,
    slx_scope: Optional[List[str]] = None,
) -> Dict:
    """Perform a task search as the given persona."""
    slx_scope = slx_scope or []
    try:
        ws = import_platform_variable("RW_WORKSPACE")
        root = import_platform_variable("RW_WORKSPACE_API_URL")
    except ImportError:
        return {}

    if "--" not in persona:
        persona = f"{ws}--{persona}"

    url = f"{root}/{ws}/task-search"
    body = {"query": [query], "scope": slx_scope, "persona": persona}

    token = os.getenv("RW_USER_TOKEN")
    if token:
        sess = requests.Session()
        sess.headers.update({
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        })
    else:
        sess = platform.get_authenticated_session()

    return _post_json(sess, url, body)


def perform_task_search(
    query: str,
    slx_scope: Optional[List[str]] = None,
) -> Dict:
    """Perform a task search with no persona."""
    slx_scope = slx_scope or []
    try:
        ws = import_platform_variable("RW_WORKSPACE")
        root = import_platform_variable("RW_WORKSPACE_API_URL")
    except ImportError:
        return {}

    url = f"{root}/{ws}/task-search"
    body = {"query": [query], "scope": slx_scope}

    token = os.getenv("RW_USER_TOKEN")
    if token:
        sess = requests.Session()
        sess.headers.update({
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        })
    else:
        sess = platform.get_authenticated_session()

    return _post_json(sess, url, body)


def build_task_report_md(
    search_response: Dict,
    score_threshold: float = 0.7,
    heading: str = "### Candidate Tasks (score ≥ {th})",
) -> Tuple[str, int]:
    """
    Build a Markdown table of tasks whose score ≥ threshold and
    ALSO return the *total* number of tasks in the search_response.

    Returns:
        (markdown_table: str, total_tasks: int)
    """
    tasks = [
        t for t in search_response.get("tasks", [])
        if t.get("score", 0) >= score_threshold
    ]
    total_tasks = len(tasks)
    
    # ── early-out when nothing passes the threshold ───────────────
    if not tasks:
        md = f"**No tasks found above confidence of {score_threshold}**"
        return md, total_tasks

    # ── build the markdown table ─────────────────────────────────
    tasks.sort(key=lambda t: t.get("score", 0), reverse=True)
    lines: List[str] = [heading.format(th=score_threshold), ""]
    lines += [
        "| Score | Access | SLX Alias | Task title |",
        "|:----:|:-------|-----------|------------|",
    ]

    def first_access(tags: List[str] | None) -> str:
        if not tags:
            return "—"
        for tg in tags:
            if tg.startswith("access:"):
                return tg.split(":", 1)[1]
        return "—"

    for t in tasks:
        score = f"{t.get('score', 0):.3f}"
        if "workspaceTask" in t:
            ws_t = t["workspaceTask"]
            alias = ws_t.get("slxAlias") or ws_t.get("slxName")
            title = ws_t.get("resolvedTitle") or ws_t.get("unresolvedTitle")
        else:
            alias = t.get("slxAlias") or t.get("slxName")
            title = t.get("resolvedTaskName") or t.get("taskName")
        access = first_access(t.get("codebundleTaskTags"))
        lines.append(f"| {score} | {access} | {alias} | {title} |")

    lines.append("")  # trailing newline
    md = "\n".join(lines)
    return md, total_tasks


def perform_improved_task_search(
    entity_data: List[str],
    persona: str,
    confidence_threshold: float = 0.7,
    slx_scope: Optional[List[str]] = None,
) -> Tuple[Dict, str, List[str], str]:
    """
    Perform an improved three-tier search strategy for webhook handlers:
    
    1. Try search with extracted entity data
    2. If no high-quality results, search with SLX spec.tag "resource_name" 
    3. If still no results, search with "child_resource" tag names
    
    Args:
        entity_data: List of entity names/identifiers extracted from webhook
        persona: Persona to use for search
        confidence_threshold: Minimum confidence score for high-quality results
        slx_scope: Optional SLX scope to limit search
        
    Returns:
        Tuple of (search_response, search_strategy_used, slx_scopes_used, search_query_used)
    """
    try:
        ws = import_platform_variable("RW_WORKSPACE")
        root = import_platform_variable("RW_WORKSPACE_API_URL")
    except ImportError:
        return {}, "failed", [], ""

    if "--" not in persona:
        persona = f"{ws}--{persona}"

    # Strategy 1: Search with extracted entity data
    if entity_data:
        entity_query = " ".join(entity_data) + " health"
        BuiltIn().log(f"[improved_search] Strategy 1: Searching with entity data: {entity_query}", level="INFO")
        
        search_response = perform_task_search_with_persona(
            query=entity_query,
            persona=persona,
            slx_scope=slx_scope
        )
        
        # Check if we have high-quality results
        high_quality_tasks = [
            t for t in search_response.get("tasks", [])
            if t.get("score", 0) >= confidence_threshold
        ]
        
        if high_quality_tasks:
            BuiltIn().log(f"[improved_search] Strategy 1 successful: {len(high_quality_tasks)} high-quality tasks found", level="INFO")
            return search_response, "entity_data", slx_scope or [], entity_query

    # Strategy 2: Search with SLX spec.tag "resource_name"
    BuiltIn().log("[improved_search] Strategy 2: Searching with resource_name tags", level="INFO")
    
    # Get SLXs with resource_name tags
    resource_name_tags = [{"name": "resource_name", "value": entity} for entity in entity_data]
    slx_list = get_slxs_with_tag(resource_name_tags)
    
    if slx_list:
        resource_slx_scopes = [slx["shortName"] for slx in slx_list]
        # Combine with existing scope if provided
        combined_scope = list(set((slx_scope or []) + resource_slx_scopes))
        
        # Try search with resource_name SLXs
        search_response = perform_task_search_with_persona(
            query="health",
            persona=persona,
            slx_scope=combined_scope
        )
        
        high_quality_tasks = [
            t for t in search_response.get("tasks", [])
            if t.get("score", 0) >= confidence_threshold
        ]
        
        if high_quality_tasks:
            BuiltIn().log(f"[improved_search] Strategy 2 successful: {len(high_quality_tasks)} high-quality tasks found", level="INFO")
            return search_response, "resource_name_tags", combined_scope, "health"

    # Strategy 3: Search with "child_resource" tag names
    BuiltIn().log("[improved_search] Strategy 3: Searching with child_resource tags", level="INFO")
    
    # Get SLXs with child_resource tags
    child_resource_tags = [{"name": "child_resource", "value": entity} for entity in entity_data]
    slx_list = get_slxs_with_tag(child_resource_tags)
    
    if slx_list:
        child_slx_scopes = [slx["shortName"] for slx in slx_list]
        # Combine with existing scope if provided
        combined_scope = list(set((slx_scope or []) + child_slx_scopes))
        
        # Try search with child_resource SLXs
        search_response = perform_task_search_with_persona(
            query="health",
            persona=persona,
            slx_scope=combined_scope
        )
        
        high_quality_tasks = [
            t for t in search_response.get("tasks", [])
            if t.get("score", 0) >= confidence_threshold
        ]
        
        if high_quality_tasks:
            BuiltIn().log(f"[improved_search] Strategy 3 successful: {len(high_quality_tasks)} high-quality tasks found", level="INFO")
            return search_response, "child_resource_tags", combined_scope, "health"

    # If all strategies fail, perform a fallback search
    BuiltIn().log("[improved_search] All strategies failed to find high-quality results, performing fallback search", level="WARN")
    
    # Always perform fallback search when no high-quality results found
    search_response = perform_task_search_with_persona(
        query="health",
        persona=persona,
        slx_scope=slx_scope
    )
    
    return search_response, "fallback", slx_scope or [], "health"