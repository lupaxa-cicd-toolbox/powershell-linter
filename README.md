<p align="center">
    <a href="https://github.com/lupaxa-cicd-toolbox">
        <img src="https://raw.githubusercontent.com/the-lupaxa-project/brand-assets/master/logos/organisations/cicd-toolbox/readme-logo.png" alt="Organisation Logo" />
    </a>
</p>

<h1 align="center">PowerShell Linter</h1>

## Overview

A tool to lint PowerShell scripts, modules, and manifests with [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) 1.25.0 or newer.

PowerShell 7 (`pwsh`) must be on `PATH`. GitHub-hosted `ubuntu-latest` runners already include it.

This tool has been tested against the following:

1. GitHub Actions
2. Travis CI
3. CircleCI
4. BitBucket pipelines
5. Local command line

Because it is a plain Bash script, it should work on most CI platforms where you can run arbitrary commands.

## Basic Usage

### GitHub Actions

```yaml
on: [push, pull_request]

jobs:
  build:
    name: PowerShell Linter
    runs-on: ubuntu-latest

    steps:
      - name: Checkout the Repository
        uses: actions/checkout@v4
      - name: Run PowerShell Linter
        run: bash <(curl -s https://raw.githubusercontent.com/lupaxa-cicd-toolbox/powershell-linter/master/src/pipeline.sh)
```

### Local

```bash
./src/pipeline.sh
```

Or without cloning:

```bash
bash <(curl -s https://raw.githubusercontent.com/lupaxa-cicd-toolbox/powershell-linter/master/src/pipeline.sh)
```

## Configuration Options

The following environment variables customise the script:

| Variable         | Default        | Purpose                                                                 |
| ---------------- | -------------- | ----------------------------------------------------------------------- |
| `INCLUDE_FILES`  | `(empty)`      | Comma-separated path regexes to force-include                           |
| `EXCLUDE_FILES`  | `(empty)`      | Comma-separated path regexes to skip                                    |
| `NO_COLOR`       | `false`        | Disable colour output                                                   |
| `REPORT_ONLY`    | `false`        | Report results but always exit 0                                        |
| `SHOW_ERRORS`    | `true`         | Show detailed errors for failed files                                   |
| `SHOW_FILTERED`  | `false`        | Show files skipped by exclude rules                                     |
| `SHOW_UNMATCHED` | `false`        | Show files that matched neither pattern                                 |
| `SCAN_ROOT`      | script default | Override scan directory without editing the script                      |
| `PSSA_SETTINGS`  | `(empty)`      | Path to a PSScriptAnalyzer settings file, instead of auto-discovery     |

> **Note:**
> If you set `INCLUDE_FILES`, only matching paths are scanned (everything else is skipped, including paths that would match `EXCLUDE_FILES`).

Without a settings file, the run reports **Error** and **Warning** and fails the file when either is present.
A syntax error fails the file as well. **Information** does not fail the file.
A `PSScriptAnalyzerSettings.psd1` in the scanned tree (or `PSSA_SETTINGS`) replaces that default.
The settings file itself is parsed, then skipped by the rule run.
The file still fails when the settings result includes an Error or a Warning.

You can combine any of the settings above:

```yaml
on: [push, pull_request]

jobs:
  build:
    name: PowerShell Linter
    runs-on: ubuntu-latest

    steps:
      - name: Checkout the Repository
        uses: actions/checkout@v4
      - name: Run PowerShell Linter
        env:
          REPORT_ONLY: true
          SHOW_ERRORS: true
        run: bash <(curl -s https://raw.githubusercontent.com/lupaxa-cicd-toolbox/powershell-linter/master/src/pipeline.sh)
```

## Example Output

```text
--------------------------------------------------------------------- Stage 1: Parameters --
 No parameters given
---------------------------------------------------------- Stage 2: Install Prerequisites --
 [ OK ] PSScriptAnalyzer is already installed
------------------------------------------------- Stage 3: Run PSScriptAnalyzer (v1.25.0) --
 [ ✅ ] src/Clean.ps1
 [ ❌ ] src/Risky.ps1
------------------------------------------------------------------------- Stage 4: Report --
 Total: 2 Passed: 1 Failed: 1 Filtered: 0 Unmatched: 0
----------------------------------------------------------------------- Stage 5: Complete --
```

## File Identification

`file` does not recognise PowerShell sources, so targets are identified by extension only:

```shell
[[ ${filename} =~ \.(ps1|psm1|psd1)$ ]]
```

<a href="https://github.com/the-lupaxa-project">
    <img src="https://raw.githubusercontent.com/the-lupaxa-project/brand-assets/master/logos/components/footer-for-child-orgs.svg" alt="The Lupaxa Project Footer" width="100%" />
</a>
