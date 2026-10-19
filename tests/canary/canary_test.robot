*** Settings ***
Documentation    Canary test to verify variable injection and secret protection.
...              Includes tests that Log values and fail assertions to exercise
...              artifact leakage paths in output.xml, log.html, report.html.
Library          Collections
Library          String

*** Variables ***
${BASE_URL}           http://localhost
${TARGET_URL}         http://localhost
${ALLOWLISTED_VAR}    default_value
${TEST_CONFIG}        default_config
${CANARY_EXPECTED}    ALLOWED_VALUE_ABCDE

*** Test Cases ***
Verify BASE_URL Is Available
    [Documentation]    BASE_URL should be injected from target_url
    [Tags]    smoke
    Should Not Be Empty    ${BASE_URL}

Verify TARGET_URL Is Available
    [Documentation]    TARGET_URL should be injected from target_url
    [Tags]    smoke
    Should Not Be Empty    ${TARGET_URL}

Verify Allowlisted Variable Works
    [Documentation]    RF_ prefixed variables should be available and have correct value
    [Tags]    smoke
    Should Not Be Empty    ${ALLOWLISTED_VAR}
    Should Be Equal    ${ALLOWLISTED_VAR}    ${CANARY_EXPECTED}

Log Variable Value For Artifact Leakage Test
    [Documentation]    This test explicitly logs the variable value.
    ...                The value WILL appear in log.html and output.xml.
    ...                This exercises the artifact leakage path that the canary must detect.
    [Tags]    artifact-leakage
    Log    The allowlisted variable value is: ${ALLOWLISTED_VAR}
    Log    TEST_CONFIG value is: ${TEST_CONFIG}

Fail Assertion With Variable Value
    [Documentation]    This test fails with the variable in the error message.
    ...                The value WILL appear in output.xml and report.html.
    ...                This exercises the failure path for artifact leakage detection.
    [Tags]    artifact-leakage    expected-fail
    ${wrong_expected}=    Set Variable    WRONG_VALUE_THAT_WILL_NOT_MATCH
    Run Keyword And Expect Error    *${ALLOWLISTED_VAR}*    Should Be Equal    ${ALLOWLISTED_VAR}    ${wrong_expected}

Canary Test Passes
    [Documentation]    Simple pass test to ensure test suite runs
    [Tags]    smoke
    Should Be True    ${TRUE}
