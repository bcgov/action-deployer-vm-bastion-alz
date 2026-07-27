@{
    # Repo-wide PSScriptAnalyzer settings, applied by .github/workflows/validate.yml
    # to both infra/deploy-terraform.ps1 and bastion-consumer-scripts/bastion-proxy.ps1.
    #
    # Each excluded rule below is a deliberate, reviewed choice for this repo's
    # interactive-CLI script style -- not an oversight. Anything not listed here
    # is expected to pass; do not add to this list without a documented reason.
    ExcludeRules = @(
        # bastion-proxy.ps1 is an interactive console tool meant to be run
        # directly by a human; Write-Host is the correct choice for its terminal
        # output, not library code that needs to compose with the output
        # pipeline. (deploy-terraform.ps1 no longer uses Write-Host -- it logs to
        # stderr so its output redirects the same way deploy-terraform.sh's does.)
        'PSAvoidUsingWriteHost',

        # These are private, script-internal helpers, not published cmdlets --
        # adding ShouldProcess/-WhatIf plumbing to them would be unwarranted
        # ceremony for scripts with no reusable module surface.
        'PSUseShouldProcessForStateChangingFunctions',

        # False positive: flags top-level script parameters that are only
        # referenced inside a function defined later in the same script -- a
        # known limitation of this rule's static analysis, not a real unused
        # parameter.
        #
        # Verify this claim per-parameter before relying on it. It previously
        # masked a genuinely unused -Mode parameter in deploy-terraform.ps1
        # (now logged on every `deploy`); a suppression that hides one real
        # finding among four false ones is worse than no suppression at all.
        # To re-check:
        #   Invoke-ScriptAnalyzer -Path <script> -IncludeRule PSReviewUnusedParameter
        # then confirm each flagged parameter is referenced somewhere in the file.
        'PSReviewUnusedParameter'
    )
}
