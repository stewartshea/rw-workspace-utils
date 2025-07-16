import re, logging, json, jmespath, requests, os
from datetime import datetime
from robot.libraries.BuiltIn import BuiltIn
from collections import Counter
from collections import defaultdict
from typing import Dict, List, Any

from RW.Core import Core
from RW import platform
from RW.Workspace import import_platform_variable


logger = logging.getLogger(__name__)

ROBOT_LIBRARY_SCOPE = "GLOBAL"

SHELL_HISTORY: list[str] = []
SECRET_PREFIX = "secret__"
SECRET_FILE_PREFIX = "secret_file__"


def get_runsession_url(rw_runsession=None):
    """Return a direct link to the RunSession."""
    try:
        if not rw_runsession:
            rw_runsession = import_platform_variable("RW_SESSION_ID")
        rw_workspace = os.getenv("RW_WORKSPACE")
        rw_workspace_app_url = os.getenv("RW_FRONTEND_URL")
    except ImportError:
        BuiltIn().log(f"Failure getting required variables", level='WARN')
        return None

    runsession_url = f"{rw_workspace_app_url}/map/{rw_workspace}?selectedRunSessions={rw_runsession}"
    return runsession_url

def get_runsession_source(payload: dict) -> str:
    """
    Given a RunWhen payload dictionary, return the "source" string based on:
      1) If top-level "source" key exists, return that
      2) Otherwise, look at the first (earliest) runRequest by 'created' time, and
         check in order:
             fromSearchQuery, fromIssue, fromSliAlert, fromAlert
         Return the name of whichever key is non-null. 
      3) If nothing is found, return "Unknown".
    """

    # 1) Check for a top-level 'source' key
    if "source" in payload:
        return payload["source"]

    # 2) Otherwise, examine runRequests
    run_requests = payload.get("runRequests", [])
    if not run_requests:
        return "Unknown"

    # Sort runRequests by created time to find the earliest
    def _parse_iso_datetime(dt: str) -> datetime:
        # '2025-02-11T08:49:06.773513Z' -> parse with replacement of 'Z' to '+00:00'
        return datetime.fromisoformat(dt.replace("Z", "+00:00"))

    sorted_requests = sorted(run_requests, key=lambda rr: _parse_iso_datetime(rr["created"]))
    earliest_rr = sorted_requests[0]

    # 3) Check the relevant fields in the earliest runRequest
    source_keys = ["fromSearchQuery", "fromIssue", "fromSliAlert", "fromAlert"]
    for key in source_keys:
        val = earliest_rr.get(key)
        if val:
            # "fromSearchQuery" -> "searchQuery"
            # "fromIssue"       -> "issue"
            # "fromSliAlert"    -> "sliAlert"
            # "fromAlert"       -> "alert"
            stripped = key[4:]  # removes "from", leaving e.g. "SearchQuery"
            # optionally lowercase the first character:
            stripped = stripped[0].lower() + stripped[1:]
            return stripped
    # 4) If no source found
    return "Unknown"


def count_open_issues(data: str):
    """Return a count of issues that have not been closed."""
    open_issues = 0 
    runsession = json.loads(data) 
    for run_request in runsession.get("runRequests", []):
        for issue in run_request.get("issues", []): 
            if not issue["closed"]:
                open_issues+=1
    return(open_issues)

def get_open_issues(data: str):
    """Return a count of issues that have not been closed."""
    open_issue_list = []
    runsession = json.loads(data) 
    for run_request in runsession.get("runRequests", []):
        for issue in run_request.get("issues", []): 
            if not issue["closed"]:
                open_issue_list.append(issue)
    return open_issue_list

def generate_open_issue_markdown_table(data_list):
    """Generates a markdown report sorted by severity."""
    severity_mapping = {1: "🔥 Critical", 2: "🔴 High", 3: "⚠️ Medium", 4: "ℹ️ Low"}
    
    # Sort data by severity (ascending order)
    sorted_data = sorted(data_list, key=lambda x: x.get("severity", 4))
    
    markdown_output = "-----\n"
    for data in sorted_data:
        severity = severity_mapping.get(data.get("severity", 4), "Unknown")
        title = data.get("title", "N/A")
        next_steps = data.get("nextSteps", "N/A").strip()
        details = data.get("details", "N/A")
        
        markdown_output += f"#### {title}\n\n- **Severity:** {severity}\n\n- **Next Steps:**\n{next_steps}\n\n"
        markdown_output += f"- **Details:**\n```json\n- {details}\n```\n\n"
    
    return markdown_output

def get_open_issues(data: str):
    """Return a count of issues that have not been closed."""
    open_issue_list = []
    runsession = json.loads(data) 
    for run_request in runsession.get("runRequests", []):
        for issue in run_request.get("issues", []): 
            if not issue["closed"]:
                open_issue_list.append(issue)
    return open_issue_list

def summarize_runsession_users(data: str, output_format: str = "text") -> str:
    """
    Parse a JSON string representing a RunWhen 'runsession' object
    (with 'runRequests' entries), gather the unique participants and
    the engineering assistants involved, and return a summary in either
    plain text or Markdown format.

    :param data: JSON string with top-level 'runRequests' list, each item
                 possibly containing 'requester' and 'persona->spec->fullName'.
    :param output_format: "text" or "markdown" (default: "text").
    :return: A string summarizing the participants and engineering assistants.
    """
    try:
        runsession = json.loads(data)
    except json.JSONDecodeError:
        # If the payload is not valid JSON, handle or raise
        return "Error: Could not decode JSON from input."

    # Prepare sets to avoid duplicates
    participants = set()
    engineering_assistants = set()

    # Gather data from each runRequest if present
    for request in runsession.get("runRequests", []):
        # Extract persona full name
        persona = request.get("persona") or {}
        spec = persona.get("spec") or {}
        persona_full_name = spec.get("fullName", "Unknown")

        # Extract requester
        requester = request.get("requester")
        if not requester:
            requester = "Unknown"

        # Normalize system requesters
        if "@workspaces.runwhen.com" in requester:
            requester = "RunWhen System"

        # Add to sets
        participants.add(requester)
        engineering_assistants.add(persona_full_name)

    # Format output
    if output_format.lower() == "markdown":
        # Construct a Markdown list
        lines = ["#### Participants:"]
        # Participants
        for participant in sorted(participants):
            lines.append(f"- {participant}")
        # Engineering assistants
        lines.append("\n#### Engineering Assistants:")
        for assistant in sorted(engineering_assistants):
            lines.append(f"- {assistant}")
        return "\n".join(lines)
    else:
        # Plain text
        text_lines = []
        text_lines.append("Participants:")
        for participant in sorted(participants):
            text_lines.append(f"  - {participant}")
        text_lines.append("")
        text_lines.append("Engineering Assistants:")
        for assistant in sorted(engineering_assistants):
            text_lines.append(f"  - {assistant}")
        return "\n".join(text_lines)

def extract_issue_keywords(data: str):
    runsession = json.loads(data) 
    issue_keywords = set()
    
    for request in runsession.get("runRequests", []):
        issues = request.get("issues", [])
        
        for issue in issues:
            if not issue.get("closed", False):
                matches = re.findall(r'`(.*?)`', issue.get("title", ""))
                issue_keywords.update(matches)
    
    return list(issue_keywords)

def get_most_referenced_resource(data: str):
    runsession = json.loads(data) 
    
    keyword_counter = Counter()
    
    for request in runsession.get("runRequests", []):
        issues = request.get("issues", [])
        
        for issue in issues:
            matches = re.findall(r'`(.*?)`', issue.get("title", ""))
            keyword_counter.update(matches)
    
    most_common_resource = keyword_counter.most_common(1)
    
    return most_common_resource[0][0] if most_common_resource else "No keywords found"

def create_runsession_from_task_search(
    *,
    search_response: dict,
    persona_shortname: str = "",
    source: str = "searchQuery",
    score_threshold: float = 0.3,
    runsession_prefix: str = "automated",
    notes: str = "",
    api_token: platform.Secret | None = None,
    rw_api_url: str | None = None,
    rw_workspace: str | None = None,
    dry_run: bool = False,
) -> dict | str:
    """Create a RunSession from a task-search response."""

    # ── 0. workspace / API root ────────────────────────────────────────────
    try:
        if rw_workspace is None:
            rw_workspace = import_platform_variable("RW_WORKSPACE")
        if rw_api_url is None:
            rw_api_url = import_platform_variable("RW_WORKSPACE_API_URL")
    except ImportError as e:
        BuiltIn().log(f"[create_runsession] env var missing: {e}", level="WARN")
        return {}

    url = f"{rw_api_url.rstrip('/')}/{rw_workspace}/runsessions"

    # ── 1. Convert tasks → runRequests ─────────────────────────────────────
    tasks: List[dict] = search_response.get("tasks", [])
    if not tasks:
        BuiltIn().log("[create_runsession] search_response had no tasks", level="INFO")
        return {}

    new_struct = "workspaceTask" in tasks[0]
    runreq_map: Dict[str, Dict[str, Any]] = defaultdict(
        lambda: {"slxName": None, "taskTitles": [], "fromSearchQuery": source}
    )

    for t in tasks:
        if t.get("score", 0) < score_threshold:
            continue

        if new_struct:
            ws    = t["workspaceTask"]
            slx   = ws.get("slxShortName") or ws.get("slxName")
            title = ws.get("unresolvedTitle") or ws.get("resolvedTitle")
        else:
            slx   = t.get("slxShortName") or t.get("slxName")
            title = t.get("taskName")      or t.get("resolvedTaskName")

        if not slx or not title:
            continue
        if not slx.startswith(f"{rw_workspace}--"):
            slx = f"{rw_workspace}--{slx}"

        rr = runreq_map[slx]
        rr["slxName"] = slx
        rr["taskTitles"].append(title)

    run_requests = list(runreq_map.values())
    if not run_requests:
        BuiltIn().log("[create_runsession] no tasks above threshold", level="INFO")
        return {}

    # ── 2. Build payload (persona only at root) ────────────────────────────
    body: dict = {
        "generateName": runsession_prefix,
        "runRequests":  run_requests,
        "active": True,
    }
    if persona_shortname:
        body["persona_name"] = f"{rw_workspace}--{persona_shortname}"
    if notes:
        body["notes"] = notes

    if dry_run:
        return body

    # ── 3. Auth headers ────────────────────────────────────────────────────
    sess = requests.Session()
    if api_token:
        sess.headers["Authorization"] = f"Bearer {api_token.value}"
    elif os.getenv("RW_USER_TOKEN"):
        sess.headers["Authorization"] = f"Bearer {os.environ['RW_USER_TOKEN']}"

    # ── 4. POST ────────────────────────────────────────────────────────────
    try:
        resp = sess.post(url, json=body, timeout=30)  # Increased timeout from 10 to 30 seconds
        resp.raise_for_status()
        return resp.json()
    except requests.RequestException as e:
        BuiltIn().log(
            f"[create_runsession] POST failed: "
            f"{getattr(resp, 'status_code', '')} {getattr(resp, 'text', str(e))}",
            level="WARN",
        )
        return {}

def get_persona_details(
    persona: str,
) -> dict:
    """
    Get persona configuration details

    :param persona: The personaShortName

    :return: Parsed JSON response of the persona configuration.
    """
    try:
        rw_workspace = import_platform_variable("RW_WORKSPACE")
        rw_workspace_api_url = import_platform_variable("RW_WORKSPACE_API_URL")
    except ImportError as e:
        BuiltIn().log(f"Missing required platform variables: {e}", level="WARN")
        return {}

    url = f"{rw_workspace_api_url}/{rw_workspace}/personas/{persona}"

    user_token = os.getenv("RW_USER_TOKEN")
    if user_token:
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {user_token}"
        }
        session = requests.Session()
        session.headers.update(headers)
    else:
        session = platform.get_authenticated_session()


    try:
        response = session.get(url, timeout=30, verify=platform.REQUEST_VERIFY)  # Increased timeout from 10 to 30 seconds
        response.raise_for_status()
        return response.json()
    except (requests.RequestException, json.JSONDecodeError) as e:
        BuiltIn().log(f"Persona fetch failed: {e}", level="WARN")
        platform_logger.exception(e)
        return {}

def add_tasks_to_runsession_from_search(
    search_response: dict,
    runsession_id: str | None = None,          
    api_token: platform.Secret = None,           
    rw_api_url: str         = "https://papi.beta.runwhen.com/api/v3",
    rw_workspace: str       = "my-workspace",
    score_threshold: float  = 0.7,
    source_query: str | None = None,
    dry_run: bool           = False,
):
    """
    Append tasks (score ≥ threshold) from *search_response* to an existing
    RunSession <runsession_id>.

    • Builds a JSON-Merge-Patch body:
        {
          "runRequests": [
            { "slxName": "...", "fromSearchQuery": "...", "taskTitles": [...] },
            …
          ]
        }
    • Sends PATCH /workspaces/<ws>/runsessions/<id>
      Content-Type: application/merge-patch+json

    Returns:
        • The server's JSON response (on success)  –or–
        • The patch body (when dry_run=True).
    """
    # ── 0. Resolve env defaults ────────────────────────────────────────────
    try:
        if rw_workspace == "my-workspace":
            rw_workspace = import_platform_variable("RW_WORKSPACE")
        if rw_api_url == "https://papi.beta.runwhen.com/api/v3":
            rw_api_url = import_platform_variable("RW_WORKSPACE_API_URL")
        if runsession_id is None:
            runsession_id = import_platform_variable("RW_SESSION_ID")
    except ImportError as e:
        BuiltIn().log(f"[patch_runsession] Missing env var: {e}", level="WARN")
        return {}

    # ── 1. Filter tasks by score ───────────────────────────────────────────
    tasks = search_response.get("tasks", [])
    if not tasks:
        BuiltIn().log("[patch_runsession] No tasks in search_response", level="INFO")
        return {}

    new_struct = "workspaceTask" in tasks[0]
    task_pairs: List[tuple[str, str]] = []

    for t in tasks:
        if t.get("score", 0) < score_threshold:
            continue

        if new_struct:
            ws    = t["workspaceTask"]
            slx   = ws.get("slxShortName") or ws.get("slxName")
            title = ws.get("unresolvedTitle") or ws.get("resolvedTitle")
        else:
            slx   = t.get("slxShortName") or t.get("slxName")
            title = t.get("taskName") or t.get("resolvedTaskName")

        if not slx or not title:
            continue

        if not slx.startswith(f"{rw_workspace}--"):
            slx = f"{rw_workspace}--{slx}"

        task_pairs.append((slx, title))

    if not task_pairs:
        BuiltIn().log("[patch_runsession] No tasks met the score threshold", level="INFO")
        return {}

    # ── 2. Build merge-patch body ──────────────────────────────────────────
    runreq_map: Dict[str, Dict[str, Any]] = defaultdict(
        lambda: {"slxName": None, "taskTitles": [], "fromSearchQuery": source_query}
    )
    for slx, title in task_pairs:
        rr = runreq_map[slx]
        rr["slxName"] = slx
        rr["taskTitles"].append(title)

    patch_body = {"runRequests": list(runreq_map.values())}

    if dry_run:
        return patch_body

    # ── 3. PATCH the RunSession ──────────────────────────────────────────────
    base = rw_api_url.rstrip("/")                #  ➜ “…/api/v3”  or “…/api/v3/workspaces”
    if not base.endswith("/workspaces"):
        base += "/workspaces" 
    url = f"{base}/{rw_workspace}/runsessions/{runsession_id}"

    # ── 3a. Choose auth method ------------------------------------------------
    if api_token is not None:
        # explicit platform.Secret
        session = requests.Session()
        session.headers.update({"Authorization": f"Bearer {api_token.value}"})
        BuiltIn().log("[patch_runsession] using api_token parameter", level="INFO")

    elif os.getenv("RW_USER_TOKEN"):
        # local dev or ad-hoc run
        session = requests.Session()
        session.headers.update({"Authorization": f"Bearer {os.environ['RW_USER_TOKEN']}"})
        BuiltIn().log("[patch_runsession] using RW_USER_TOKEN from env", level="INFO")

    else:
        # inside a runbook/runtime – session already carries auth headers
        session = platform.get_authenticated_session()
        BuiltIn().log("[patch_runsession] using platform authenticated session", level="INFO")

    headers = {"Content-Type": "application/json"}

    BuiltIn().log(
        f"[patch_runsession] Patching RunSession {runsession_id} with "
        f"{len(task_pairs)} tasks (score ≥ {score_threshold})",
        level="INFO",
    )

    try:
        resp = session.patch(url, json=patch_body, headers=headers, timeout=30)  # Increased timeout from 10 to 30 seconds
        resp.raise_for_status()
        return resp.json()
    except requests.RequestException as e:
        BuiltIn().log(f"[patch_runsession] PATCH failed: {e}", level="WARN")
        return {}
