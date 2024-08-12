"""
PagerDuty keyword library for performing tasks for interacting with PagerDuty incidents.

Scope: Global
"""

import re, logging, json, jmespath, requests, os
from datetime import datetime
from robot.libraries.BuiltIn import BuiltIn

from RW import platform
from RW.Core import Core
from RW.Workspace import workspace_utils


logger = logging.getLogger(__name__)

ROBOT_LIBRARY_SCOPE = "GLOBAL"

SHELL_HISTORY: list[str] = []
SECRET_PREFIX = "secret__"
SECRET_FILE_PREFIX = "secret_file__"


def get_user_email(
    userid: str,
    secret_token: platform.Secret = None,
):
    """Gets user email from incident Json, which is needed to add
    notes to the incident. 

    Args:
        userid (str): the PagerDuty user ID to look up
        secret_token (platform.Secret): the token needed for PD auth

    Returns:
        email: email address of the userID 
    """
    headers = {
        "Authorization": f"Token token={secret_token.value}"
    }
    url = f"https://api.pagerduty.com/users/{userid}"

    try:
        response = requests.get(url, headers=headers, timeout=10)
        if response.status_code == 200:
            user_data = response.json()
            email = user_data.get('user', {}).get('email')
            return email
    except requests.exceptions.RequestException as e:
        print(f"An error occurred: {e}")
        return None

def add_runsession_note_to_incident(
    data: dict,
    secret_token: platform.Secret = None,
):
    """Gets user email from incident Json, which is needed to add
    notes to the incident. 

    Args:
        incident (dict): the PagerDuty user ID to look up
        secret_token (platform.Secret): the token needed for PD auth

    Returns:
        email: email address of the userID 
    """

    try:
        rw_runsession = workspace_utils.import_platform_variable("RW_SESSION_ID")
        rw_workspace = workspace_utils.import_platform_variable("RW_WORKSPACE")
        rw_workspace_api_url = workspace_utils.import_platform_variable("RW_WORKSPACE_API_URL")
    except ImportError:
        BuiltIn().log(f"Failure importing required variables", level='WARN')
        return None


    userid=data.get('event', {}).get('agent', {}).get('id')
    incidentid=data.get('event', {}).get('data', {}).get('id')
    user_email=get_user_email(userid, secret_token)

    app_url = rw_workspace_api_url.replace("papi", "app").split("/api")[0]
    runsession_url=f"{app_url}/map/{rw_workspace}?selectedRunSessions={rw_runsession}"


    headers = {
        "Authorization": f"Token token={secret_token.value}",
        "From": f"{user_email}",
        "Content-Type": "application/json",
        "Accept": "application/vnd.pagerduty+json;version=2"
    }

    note = {
        "note": {
            "content": f"RunSession started in workspace {rw_workspace}.\n[RunSession URL - {runsession_url}]"
        }
    }
    url = f"https://api.pagerduty.com/incidents/{incidentid}/notes"

    try:
        response = requests.post(url, json=note, headers=headers, timeout=10)
        if response.status_code == 200:
            return response
    except requests.exceptions.RequestException as e:
        print(f"An error occurred: {e}")
        return None
