*** Settings ***
Documentation    Canary test suite that ACTUALLY FAILS to verify:
...              1. Entrypoint exits non-zero when tests fail
...              2. Artifact scrubbing still works on failed test output
...              3. RF variable values in FAIL messages are scrubbed from artifacts
...              NOTE: Console FAIL summary may show plaintext values (documented limitation)
Library          Collections
Library          String

*** Variables ***
${CANARY_VAR_1}       canary-default-1
${CANARY_VAR_2}       canary-default-2
${CANARY_QUOTED}      canary-default-quoted

*** Test Cases ***
Fail With RF Variable In Assertion
    [Documentation]    This test FAILS with RF variable value in the error message.
    ...                The CANARY_VAR_1 value will appear in output.xml, log.html, 
    ...                report.html (scrubbed), and console FAIL summary (may be plaintext).
    [Tags]    intentional-fail
    Log    Testing CANARY_VAR_1 in assertion failure path
    Should Be Equal    ${CANARY_VAR_1}    wrong-expected-value-xyz
    ...    msg=Assertion failed comparing RF variable

Fail With Special Chars Variable
    [Documentation]    This test FAILS with special chars RF variable in error.
    ...                Tests scrubbing of & < > " / $ | @ in failure messages.
    [Tags]    intentional-fail
    Log    Testing CANARY_VAR_2 with special chars in failure
    Should Be Equal    ${CANARY_VAR_2}    wrong-value-for-special
    ...    msg=Special chars variable mismatch

Fail With Quoted Variable
    [Documentation]    This test FAILS with quoted RF variable containing all special chars.
    ...                Tests full escaped variant scrubbing in failure path.
    [Tags]    intentional-fail
    Log    Testing CANARY_QUOTED with quotes and special chars
    Should Be Equal    ${CANARY_QUOTED}    wrong-quoted-value
    ...    msg=Quoted variable comparison failed
