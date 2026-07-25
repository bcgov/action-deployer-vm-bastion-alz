@{
    # Repo-wide PSScriptAnalyzer settings, applied by .github/workflows/validate.yml
    # to both infra/deploy-terraform.ps1 and bastion-consumer-scripts/bastion-proxy.ps1.
    #
    # Each excluded rule below is a deliberate, reviewed choice for this repo's
    # interactive-CLI script style -- not an oversight. Anything not listed here
    # is expected to pass; do not add to this list without a documented reason.
    ExcludeRules = @(
        # Both scripts are interactive console tools meant to be run directly by
        # a human; Write-Host is the correct choice for terminal output here,
        # not library code that needs to compose with the output pipeline.
        'PSAvoidUsingWriteHost',

        # These are private, script-internal helpers, not published cmdlets --
        # adding ShouldProcess/-WhatIf plumbing to them would be unwarranted
        # ceremony for scripts with no reusable module surface.
        'PSUseShouldProcessForStateChangingFunctions',

        # False positive: flags top-level script parameters that are only
        # referenced inside a function defined later in the same script -- a
        # known limitation of this rule's static analysis, not a real unused
        # parameter.
        'PSReviewUnusedParameter'
    )
}
