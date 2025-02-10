import json, requests
from RW import platform


def create_github_issue(title, body, github_token: platform.Secret, repo, github_server="https://api.github.com"):
    """Creates a GitHub issue with the given title and body."""
    url = f"{github_server}/repos/{repo}/issues"
    headers = {
        "Authorization": f"token {github_token.value}",
        "Accept": "application/vnd.github.v3+json"
    }
    data = {
        "title": title,
        "body": body
    }
    response = requests.post(url, headers=headers, json=data)
    response.raise_for_status()
    return response.json()