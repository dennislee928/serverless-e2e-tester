*** Settings ***
Documentation    Canary test suite that ACTUALLY FAILS to verify:
...              1. Entrypoint exits non-zero when tests fail
...              2. Artifact scrubbing still works on failed test output
...              3. Variable values in FAIL messages are handled
Library          Collections
Library          String

*** Variables ***
${ALLOWLISTED_VAR}    default_value
${SPECIAL_CHARS}      default_special
${FAIL_MESSAGE}       This test intentionally fails

*** Test Cases ***
Intentional Failure With Variable In Message
    [Documentation]    This test ACTUALLY FAILS (not expected-error).
    ...                The failure message contains variables that will appear
    ...                in output.xml, log.html, report.html, and console summary.
    [Tags]    intentional-fail
    Log    About to fail with ALLOWLISTED_VAR: ${ALLOWLISTED_VAR}
    Log    And SPECIAL_CHARS: ${SPECIAL_CHARS}
    Fail    ${FAIL_MESSAGE} - check value handling

Another Intentional Failure
    [Documentation]    Second failure to ensure multiple failures are handled
    [Tags]    intentional-fail
    Should Be Equal    actual_value    expected_but_different    msg=Values don't match
