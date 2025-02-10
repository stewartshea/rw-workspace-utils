# File: RW/Slack.py

import requests
from RW import platform
from robot.api.deco import keyword
from robot.libraries.BuiltIn import BuiltIn

class Slack:
    @keyword("Send Slack Message")
    def send_slack_message(
        self,
        webhook_url: platform.Secret,
        blocks=None,
        attachments=None,
        text=None,
        channel=None
    ):
        """
        Sends a Slack message to the specified webhook URL.

        :param webhook_url: (platform.Secret) Slack Incoming Webhook URL
        :param blocks: (Optional) A Python list of top-level Block Kit blocks.
        :param attachments: (Optional) A list of Slack attachments (color-coded sidebars).
        :param text: (Optional) Plaintext fallback if blocks/attachments not used.
        :param channel: (Optional) A string to override the default channel, e.g. "#some-other-channel".

        Note: Overriding the channel may be ignored if your Slack webhook is 
        configured for a specific channel and does not allow overrides.
        """
        BuiltIn().log(f"Sending Slack message to {webhook_url.value}", level="INFO")

        payload = {}
        # If you want to override the channel, set it here
        if channel:
            payload["channel"] = channel

        if blocks:
            payload["blocks"] = blocks
        if attachments:
            payload["attachments"] = attachments
        if text:
            payload["text"] = text

        try:
            response = requests.post(webhook_url.value, json=payload, timeout=10)
            if response.status_code != 200:
                raise AssertionError(
                    f"Error sending Slack message: {response.status_code} - {response.text}"
                )
            return response.text
        except requests.RequestException as e:
            raise AssertionError(f"Exception sending Slack message: {e}")

    @keyword("Create RunSession Summary Payload")
    def create_runsession_summary_payload(
        self,
        title,
        open_issue_count,
        users,
        open_issues,
        runsession_url=None
    ):
        """
        Build a Slack message with:
          - Top-level blocks for the run session summary (including a header block).
          - Attachments for each issue, color-coded based on severity.

        Slack disallows 'header' blocks INSIDE attachments, so we keep the header
        at top-level blocks. Each issue is a separate attachment with a colored bar.

        :param title: (str) Main RunSession title (e.g., "[RunWhen] 4 open issue(s)...").
        :param open_issue_count: (int) e.g., 4
        :param users: (str) e.g., "- Eager Edgar\n- RunWhen System"
        :param open_issues: (list of dicts), each has:
            {
              "severity": (int) 1..4,
              "title": (str),
              "nextSteps": (str) multi-line
            }
        :param runsession_url: (str) Optional link to the RunSession.
        :return: (blocks, attachments) 
                 blocks: top-level Slack blocks
                 attachments: a list of attachments, each with color-coded severity
        """

        # ---------------- 1) TOP-LEVEL BLOCKS ----------------
        blocks = []

        # (a) Header Block
        blocks.append({
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": title,
                "emoji": True
            }
        })

        # (b) Section with fields for open issue count & participants
        summary_section = {
            "type": "section",
            "fields": [
                {
                    "type": "mrkdwn",
                    "text": f"*Open Issues:*\n{open_issue_count}"
                },
                {
                    "type": "mrkdwn",
                    "text": f"*Participants:*\n{users}"
                }
            ]
        }
        blocks.append(summary_section)

        # (c) Optional divider
        blocks.append({"type": "divider"})

        # (d) Possibly add a "context" block at the end with runsession_url
        # We'll do that after attachments if we want.

        # ---------------- 2) ATTACHMENTS PER ISSUE ----------------
        severity_colors = {
            1: "#FF0000",   # Critical => red
            2: "#FFA500",   # Major => orange
            3: "#00BFFF",   # Minor => blue
            4: "#808080"    # Info => grey
        }

        # Sort issues ascending => severity=1 on top
        sorted_issues = sorted(open_issues, key=lambda x: x.get("severity", 4))

        attachments = []
        for idx, issue in enumerate(sorted_issues, start=1):
            sev = issue.get("severity", 4)
            attach_color = severity_colors.get(sev, "#808080")

            issue_title = issue.get("title", "Untitled Issue")
            raw_steps = issue.get("nextSteps", "")  # multi-line string
            step_lines = [ln.strip() for ln in raw_steps.splitlines() if ln.strip()]
            if step_lines:
                bullet_points = "\n  - ".join(step_lines)
                next_steps_str = f"> *Next Steps:*\n  - {bullet_points}"
            else:
                next_steps_str = "> *Next Steps:*\n  - _No next steps provided._"

            # Use a horizontal line for clarity
            issue_text = (
                f"{idx}) *{issue_title}*\n"
                "────────────────────────────────────────\n"
                f"{next_steps_str}"
            )

            attachments.append({
                "color": attach_color,
                "blocks": [
                    {
                        "type": "section",
                        "text": {
                            "type": "mrkdwn",
                            "text": issue_text
                        }
                    }
                ]
            })

        # ---------------- 3) (Optional) ADD RUNSESSION LINK AS A CONTEXT BLOCK ----------------
        # If we want it at top-level, we add a new block:
        if runsession_url:
            blocks.append({
                "type": "context",
                "elements": [
                    {
                        "type": "mrkdwn",
                        "text": f"<{runsession_url}|View the RunSession for more details>"
                    }
                ]
            })

        # Return a tuple: (top-level blocks, color-coded attachments)
        return (blocks, attachments)
