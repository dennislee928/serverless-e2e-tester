*** Settings ***
Documentation    Canary test to verify variable injection and secret protection.
...              Logs variable values to exercise artifact scrubbing paths.
...              All values use canary- prefix for clear test identification.
Library          Collections
Library          String

*** Variables ***
${BASE_URL}           http://localhost
${TARGET_URL}         http://localhost
${CANARY_VAR_1}       canary-default-1
${CANARY_VAR_2}       canary-default-2
${CANARY_QUOTED}      canary-default-quoted

*** Test Cases ***
Log BASE_URL With Double Slash
    [Documentation]    Log BASE_URL which contains // to test URL scrubbing
    [Tags]    artifact-leakage
    Log    BASE_URL value is: ${BASE_URL}
    Should Not Be Empty    ${BASE_URL}

Log TARGET_URL Value
    [Documentation]    Log TARGET_URL to exercise artifact leakage path
    [Tags]    artifact-leakage
    Log    TARGET_URL value is: ${TARGET_URL}
    Should Not Be Empty    ${TARGET_URL}

Log First Canary Variable
    [Documentation]    Log first RF_ prefixed canary variable
    [Tags]    artifact-leakage
    Log    CANARY_VAR_1 value is: ${CANARY_VAR_1}
    Should Not Be Empty    ${CANARY_VAR_1}

Log Second Canary Variable With Special Chars
    [Documentation]    Log second RF_ canary variable with & < > special chars
    [Tags]    artifact-leakage    special-chars
    Log    CANARY_VAR_2 value is: ${CANARY_VAR_2}
    Should Not Be Empty    ${CANARY_VAR_2}

Log Third Canary Variable With Quotes
    [Documentation]    Log third RF_ canary variable with quotes and all special chars
    ...                Contains: " & < > / $ | @
    [Tags]    artifact-leakage    special-chars    quotes
    Log    CANARY_QUOTED value is: ${CANARY_QUOTED}
    Should Not Be Empty    ${CANARY_QUOTED}

Log Truncated Userinfo Fragment
    [Documentation]    Simulate RequestsLibrary truncating URL to show userinfo fragment.
    ...                Tests scrubbing of password appearing without full URL context.
    ...                Example: when RequestsLibrary logs "connecting to canary-user:canary-pass-xyz@localhost"
    [Tags]    artifact-leakage    userinfo    truncated
    ${truncated_fragment}=    Set Variable    canary-user:canary-pass-xyz@localhost:8080
    Log    RequestsLibrary connection attempt: ${truncated_fragment}
    Should Not Be Empty    ${truncated_fragment}

Canary Test Passes
    [Documentation]    Simple pass test to ensure test suite runs
    [Tags]    smoke
    Should Be True    ${TRUE}
