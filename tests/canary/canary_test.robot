*** Settings ***
Documentation    Canary test to verify variable injection and secret protection.
...              Includes tests that Log values to exercise artifact leakage paths.
Library          Collections
Library          String

*** Variables ***
${BASE_URL}           http://localhost
${TARGET_URL}         http://localhost
${ALLOWLISTED_VAR}    default_value
${TEST_CONFIG}        default_config
${SPECIAL_CHARS}      default_special

*** Test Cases ***
Log BASE_URL With Double Slash
    [Documentation]    Log BASE_URL which contains // to test scrubbing of URLs
    [Tags]    artifact-leakage
    Log    BASE_URL value is: ${BASE_URL}
    Should Not Be Empty    ${BASE_URL}

Log TARGET_URL Value
    [Documentation]    Log TARGET_URL to exercise artifact leakage path
    [Tags]    artifact-leakage
    Log    TARGET_URL value is: ${TARGET_URL}
    Should Not Be Empty    ${TARGET_URL}

Log Allowlisted Variable
    [Documentation]    Log RF_ prefixed variable value
    [Tags]    artifact-leakage
    Log    ALLOWLISTED_VAR value is: ${ALLOWLISTED_VAR}
    Should Not Be Empty    ${ALLOWLISTED_VAR}

Log Second RF Variable
    [Documentation]    Log second RF_ prefixed variable
    [Tags]    artifact-leakage
    Log    TEST_CONFIG value is: ${TEST_CONFIG}
    Should Not Be Empty    ${TEST_CONFIG}

Log Third RF Variable With Special Chars
    [Documentation]    Log third RF_ variable containing & < > special chars
    ...                Tests that XML/HTML escaped variants are also scrubbed
    [Tags]    artifact-leakage    special-chars
    Log    SPECIAL_CHARS value is: ${SPECIAL_CHARS}
    Should Not Be Empty    ${SPECIAL_CHARS}

Canary Test Passes
    [Documentation]    Simple pass test to ensure test suite runs
    [Tags]    smoke
    Should Be True    ${TRUE}
