*** Settings ***
Metadata          Author    stewartshea
Documentation     This CodeBundle create a new GitHub Issue with the summary of open issues from the RunSession. 
...    This is intended to be used at the end of a RunSession if open issues exist and need further action.
Metadata          Supports     GitHub   RunWhen
Metadata          Display Name     GitHub - Create Issue From RunSession
Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.platform
Library           OperatingSystem
Library           RW.CLI
Library           RW.Workspace
Library           RW.GitHub
Library           RW.RunSession

*** Keywords ***
Suite Initialization
    ${GITHUB_REPOSITORY}=    RW.Core.Import User Variable    GITHUB_REPOSITORY
    ...    type=string
    ...    description=The GitHub owner and repository
    ...    pattern=\w*
    ...    example=runwhen-contrib/runwhen-local

   ${GITHUB_TOKEN}=    RW.Core.Import Secret    GITHUB_TOKEN
    ...    type=string
    ...    description=The secret containing the GitHub PAT. 
    ...    pattern=\w*

    ${CURRENT_SESSION}=    RW.Workspace.Import Runsession Details
    ${RELATED_RUNSESSION}=     RW.Workspace.Import Related RunSession Details    ${CURRENT_SESSION}
    IF    $RELATED_RUNSESSION != None
        Set Suite Variable    ${SESSION}   ${RELATED_RUNSESSION}
    ELSE
        Set Suite Variable    ${SESSION}   ${CURRENT_SESSION}
    END 

*** Tasks ***
Create GitHub Issue in Repository `${GITHUB_REPOSITORY}` from RunSession
    [Documentation]    Create a GitHub Issue with the summarized details of the RunSession. Intended to be used as a final task in a workflow. 
    [Tags]    github    issue    final    ticket    runsession
    ${session_list}=    Evaluate    json.loads(r'''${SESSION}''')    json
    ${open_issue_count}=    RW.RunSession.Count Open Issues    ${SESSION}
    ${open_issues}=    RW.RunSession.Get Open Issues    ${SESSION}
    ${issue_table}=    RW.RunSession.Generate Open Issue Markdown Table    ${open_issues}
    ${users}=    RW.RunSession.Summarize RunSession Users      
    ...    data=${SESSION}
    ...    format=markdown
    ${runsession_url}=    RW.RunSession.Get RunSession URL    ${session_list["id"]}
    ${key_resource}=    RW.RunSession.Get Most Referenced Resource    ${SESSION}
    ${source}=              RW.RunSession.Get RunSession Source    ${session_list}
    ${title}=               Set Variable    [RunWhen] ${open_issue_count} open issue(s) from ${source} related to `${key_resource}`
    
    Add Pre To Report    Title: ${title}
    Add Pre To Report    Total Open Issues:${open_issue_count}
    Add Pre To Report    Users:\n${users}
    Add Pre To Report    Open Issues:\n${issue_table}
    
    IF    $open_issue_count > 0
        ${github_issue}=    RW.GitHub.Create GitHub Issue     
        ...    title=${title}
        ...    body=### Details\n---\n[🔗 View RunSession](${runsession_url})\n\n${users}\n\n### Open Issues\n${issue_table}
        ...    github_token=${GITHUB_TOKEN}
        ...    repo=${GITHUB_REPOSITORY}
        
        # TODO Add http rsp code and open issue if rsp fails
        Add To Report    [GitHub Issue Created](${github_issue["html_url"]})
    ELSE
        Add To Report      No Open Issues Found
    END

