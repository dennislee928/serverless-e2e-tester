*** Settings ***
Documentation    Canary test to verify variable injection and secret protection
Library          Collections

*** Variables ***
${BASE_URL}         http://localhost
${ALLOWLISTED_VAR}  default_value

*** Test Cases ***
Verify BASE_URL Is Available
    [Documentation]    BASE_URL should be injected from target_url
    Should Not Be Empty    ${BASE_URL}
    Log    BASE_URL is set (value not logged for security)

Verify Allowlisted Variable Works
    [Documentation]    RF_ prefixed variables should be available
    Log    ALLOWLISTED_VAR name is available
    Should Not Be Empty    ${ALLOWLISTED_VAR}

Canary Test Passes
    [Documentation]    Simple pass test to ensure test suite runs
    Log    Canary test completed successfully
    Should Be True    ${TRUE}
