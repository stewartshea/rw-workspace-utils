*** Settings ***
Metadata          Author           stewartshea
Documentation     This CodeBundle sends a Slack message with the summary of open issues from the RunSession.
...               It is intended to be used at the end of a RunSession if open issues exist and need further action.
Metadata          Supports         Slack   RunWhen
Metadata          Display Name     Slack - Send Issue Summary From RunSession

Suite Setup       Suite Initialization

Library           BuiltIn
Library           RW.Core
Library           RW.platform
Library           OperatingSystem
Library           RW.CLI
Library           RW.Workspace
Library           RW.RunSession
Library           RW.Slack

*** Keywords ***
Suite Initialization
    ${SLACK_WEBHOOK}=    RW.Core.Import Secret    SLACK_WEBHOOK
    ...    type=string
    ...    description=Slack webhook URL used to post the notification
    ...    pattern=\w*
    ${SLACK_CHANNEL}=    RW.Core.Import User Variable    SLACK_CHANNEL
    ...    type=string
    ...    description=The Slack channel to post the message into. Note: The Webhook URL determines the channel, but can be overridden with Legacy Webhooks only. 
    ...    pattern=\w*
    ...    example=#general
    Set Suite Variable    ${SLACK_CHANNEL}    ${SLACK_CHANNEL}
    # Get the current RunSession details from the workspace
    ${CURRENT_SESSION}=      RW.Workspace.Import Runsession Details
    # Check if there is a "related" RunSession to fetch instead
    ${RELATED_RUNSESSION}=   RW.Workspace.Import Related RunSession Details    ${CURRENT_SESSION}

    # Prefer the related session if it’s available, else fall back to the current one
    IF    $RELATED_RUNSESSION != None
        Set Suite Variable    ${SESSION}   ${RELATED_RUNSESSION}
    ELSE
        Set Suite Variable    ${SESSION}   ${CURRENT_SESSION}
    END

*** Tasks ***
Send Slack Notification to Channel `${SLACK_CHANNEL}` from RunSession
    [Documentation]    Sends a Slack message containing the summarized details of the RunSession.
    ...                Intended to be used as a final task in a workflow.
    [Tags]             slack    final    notification    runsession

    # Convert the session JSON (string) to a Python dictionary/list
    ${session_list}=        Evaluate    json.loads(r'''${SESSION}''')    json

    # Gather important information about open issues in the RunSession
    ${open_issue_count}=    RW.RunSession.Count Open Issues    ${SESSION}
    ${open_issues}=         RW.RunSession.Get Open Issues      ${SESSION}
    ${issue_table}=         RW.RunSession.Generate Open Issue Markdown Table    ${open_issues}
    ${users}=               RW.RunSession.Summarize RunSession Users   ${SESSION}
    ${runsession_url}=      RW.RunSession.Get RunSession URL    ${session_list["id"]}
    ${key_resource}=        RW.RunSession.Get Most Referenced Resource    ${SESSION}
    ${source}=              RW.RunSession.Get RunSession Source    ${session_list}
    ${title}=               Set Variable    [RunWhen] ${open_issue_count} open issue(s) from ${source} related to `${key_resource}`


    ${blocks}    ${attachments}=    Create RunSession Summary Payload
    ...    title=${title}
    ...    open_issue_count=${open_issue_count}
    ...    users=${users}
    ...    open_issues=${open_issues}
    ...    runsession_url=${runsession_url}

    IF    $open_issue_count > 0
        RW.Slack.Send Slack Message    
        ...    webhook_url=${SLACK_WEBHOOK}   
        ...    blocks=${blocks}    
        ...    attachments=${attachments}    
        ...    channel=${SLACK_CHANNEL}
    
        # TODO Add http rsp code and open issue if rsp fails
        Add To Report      Slack Message Sent with Open Issues
    ELSE
        Add To Report      No Open Issues Found
    END
