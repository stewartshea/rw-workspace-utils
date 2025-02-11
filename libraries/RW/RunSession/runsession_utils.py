import re, logging, json, jmespath, requests, os
from datetime import datetime
from robot.libraries.BuiltIn import BuiltIn
from collections import Counter

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
