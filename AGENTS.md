# AGENTS.md

Guidance for AI coding agents working in this repository. Read [README.md](README.md) for user-facing detail. This file covers what you need to change code safely.

## What this repo is

`bcgov/action-deployer-vm-bastion-alz` is a **GitHub composite action**. It deploys Azure Bastion and a Linux jumpbox into a BC Gov Azure Landing Zone (ALZ) VNet. Terraform ships inside the action (`infra/`), so callers do not copy it. Callers pin the action with `@ref`.

BC Gov guardrails apply: no public IPs, no SSH keys, Microsoft Entra ID auth with Azure RBAC, OIDC (no client secrets).

## Layout

| Path | Purpose |
|---|---|
| `action.yml` | Composite action entry point. Inputs, OIDC login, calls `.github/scripts/run-deploy.sh`. |
| `.github/scripts/run-deploy.sh` | Stages tfvars, applies override inputs, runs `infra/deploy-terraform.sh`. |
| `.github/scripts/setup-repo-protection.sh` | Admin script. Sets branch protection and auto-merge with `gh api`. |
| `.github/workflows/` | `validate.yml` (PR gate), `release.yml` (tag + release on `main`), `dependabot-auto-merge.yml`. |
| `infra/` | Root Terraform module. Bastion (AVM) plus `network`, `jumpbox`, `monitoring` modules in `infra/modules/`. |
| `infra/deploy-terraform.sh` | init/plan/apply/destroy orchestration. Used in CI. |
| `infra/deploy-terraform.ps1` | Same flow for **local** use only. Must run on Windows PowerShell 5.1 and PowerShell 7. |
| `infra/tests/deploy-terraform.tests.ps1` | Behavioural tests for the `.ps1` script. |
| `bastion-consumer-scripts/` | `bastion-proxy.sh` / `.ps1` / `.md`. Consumer tools for a SOCKS5 tunnel through Bastion. |
| `examples/` | `caller-deploy.yml`, `team.tfvars`, `local.tfvars`. Keep in sync with `infra/variables.tf`. |

Terraform backend is `backend "azurerm" {}`. `deploy-terraform.sh` injects backend values with `-backend-config`. Do not hard-code them.

## Commands

Run these before you finish. They match the `validate.yml` CI gate.

```bash
terraform fmt -check -recursive
cd infra && terraform init -backend=false -input=false && terraform validate
cd infra && tflint --init && tflint --recursive   # config: infra/.tflint.hcl
```

PowerShell (Windows runner in CI):

```powershell
Invoke-ScriptAnalyzer -Path infra/deploy-terraform.ps1,infra/tests/deploy-terraform.tests.ps1,bastion-consumer-scripts/bastion-proxy.ps1 -Severity Warning,Error -Settings ./PSScriptAnalyzerSettings.psd1
powershell.exe -NoProfile -File ./infra/tests/deploy-terraform.tests.ps1   # also run with pwsh.exe
```

`-IncludeInstall` on the test script downloads Terraform. Use it only when you need that path.

Do not run `terraform apply` or `destroy` against real subscriptions. Use `plan` only when the user asks and credentials exist.

## Conventions

- **Terraform:** `>= 1.12.0`. `azurerm >= 4.57.0, < 5.0.0` (two AVM modules cap azurerm below 5.0). Providers: `azapi`, `null`, `random`, `time`, `modtm`.
- **Minimal branching.** Avoid wide `count`-based conditional flags across many files. State the file footprint before you make a large plan.
- **Runbooks stay stdlib.** Azure Automation runbooks use Python 3.10 with the standard library only. Do not add the Azure SDK.
- **AVM policy gotcha.** The VM AVM module pins `encryption_at_host = false` because the feature is unregistered in the subscription. Verify ALZ deny policies before you change VM or network settings.
- **One Bastion per VNet.** `AzureBastionSubnet` must be unique per VNet. Jumpbox subnet names must be unique per VNet.
- **Docs:** `README.md` uses Simplified Technical English style: short active sentences, one term per concept. Match it. Update the README Inputs table and the repository-structure tree when you change `action.yml` inputs or file layout.
- **Commits:** Conventional Commits (`feat:`, `fix:`, `deps(...)`, `docs:`, `chore:`). `release.yml` computes the next version and notes from them on push to `main`.
- **Actions security:** workflows use `permissions: {}` as baseline, with per-job step-ups. Pin third-party actions by SHA. First-party actions use tags. Pass untrusted values through `env:`, never inline in `run:`. Pin runners (`ubuntu-24.04`, `windows-2025`).
- **Input changes touch several files.** A new action input usually needs edits in `action.yml`, `run-deploy.sh`, `infra/variables.tf`, `examples/`, and the README Inputs table.

## Required skills

Load these skills (from [bcgov/agent-skills](https://github.com/bcgov/agent-skills)) before you work in the matching area. They are mandatory, not optional.

| Skill | Use when you touch | Source |
|---|---|---|
| `github-actions` | `action.yml`, `.github/workflows/*.yml`, `.github/dependabot.yml`, `.github/scripts/`, branch-protection or ruleset settings. Covers deny-all `permissions`, SHA pinning, fork-gate, results aggregator, script-injection-safe `env:` handling. | [skills/github-actions](https://github.com/bcgov/agent-skills/tree/main/skills/github-actions) |
| `azure-networking` | `infra/modules/network/`, subnets, NSGs, delegation, private endpoints, `AzureBastionSubnet`, jumpbox subnet, ARM write serialization. | [skills/azure-networking](https://github.com/bcgov/agent-skills/tree/main/skills/azure-networking) |

If a task touches both areas, load both. If the skill is not available in your session, read it from the links above before you edit.

## Rules for agents

- **Do not commit, push, or open PRs unless asked.** `main` is protected: PRs, required checks, linear history, squash merge.
- **Never print or commit secrets.** Do not add client secrets, public endpoints, or `.tfvars` with real subscription or tenant IDs. Example tfvars use placeholders.
- Do not edit `infra/.terraform.lock.hcl` by hand. Dependabot updates provider pins weekly.
- Keep changes in scope. Do not refactor shell or Terraform you were not asked to touch.
- Scripts in `bastion-consumer-scripts/` ship to end users. Keep `.sh` and `.ps1` behaviour in step.
