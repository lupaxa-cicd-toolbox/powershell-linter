#!/usr/bin/env bash

# -------------------------------------------------------------------------------- #
# Description                                                                      #
# -------------------------------------------------------------------------------- #
# Generic CICD Toolbox pipeline. Copy this file into a tool repo and edit only     #
# the CONFIGURATION section below. Works from GitHub Actions, Bitbucket, Travis,   #
# and the local CLI.                                                               #
# -------------------------------------------------------------------------------- #

set -uo pipefail

# -------------------------------------------------------------------------------- #
# Minimal Bash version gate — MUST run before any `declare -A` (associative array) #
# statement below. Older Bash (< 4.0) doesn't understand `declare -A` and either   #
# errors out non-fatally (continuing with a broken script) or, on some platforms,  #
# aborts in a way that can be mistaken for success. BASH_VERSINFO is a plain       #
# indexed array supported since Bash 2.x, so it is always safe to reference here.  #
# -------------------------------------------------------------------------------- #
if [[ -z "${BASH_VERSINFO:-}" ]] || \
   (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "[ Version Error ] This script requires Bash 4.4.0 or newer (found: ${BASH_VERSION:-unknown})." >&2
    exit 1
fi

# ==================================================================================
# CONFIGURATION — edit this section for each tool
# ==================================================================================

# --- Behaviour flags -------------------------------------------------------------
DEBUG_MODE=false
UPDATE_PIP=false                 # pip tools only
INSTALL_REQUIREMENTS_FROM_REPO=false  # pip tools only

# --- Tool identity & install -----------------------------------------------------
# Examples (pick one style; delete the others from your mental model):
#   pip:    PREREQUISITE_COMMANDS=(pip)
#           PACKAGE_NAME='yamllint'
#           INSTALLED_CHECK=("${BASE_COMMAND}" --version)
#           INSTALL_COMMAND=(pip install --quiet "${PACKAGE_NAME}")
#           TEST_COMMAND=("${BASE_COMMAND}")
#
#   gem:    PREREQUISITE_COMMANDS=(gem)
#           PACKAGE_NAME='rubocop'
#           INSTALL_COMMAND=(gem install --quiet "${PACKAGE_NAME}")
#
#   npm:    PREREQUISITE_COMMANDS=(npm)
#           PACKAGE_NAME='markdownlint-cli'
#           INSTALL_COMMAND=(npm install -g "${PACKAGE_NAME}")
#
#   docker: PREREQUISITE_COMMANDS=(docker)
#           PACKAGE_NAME='koalaman/shellcheck:stable'
#           INSTALLED_CHECK=()   # empty => always pull/upgrade
#           INSTALL_COMMAND=(docker pull --quiet "${PACKAGE_NAME}")
#           TEST_COMMAND=(docker run --rm -v "${PWD}:/mnt" "${PACKAGE_NAME}")
#
#   go:     PREREQUISITE_COMMANDS=(go)
#           PACKAGE_NAME='github.com/rhysd/actionlint/cmd/actionlint@latest'
#           INSTALL_COMMAND=(go install "${PACKAGE_NAME}")
#
#   apt:    PREREQUISITE_COMMANDS=()
#           PACKAGE_NAME='jq'
#           INSTALL_COMMAND=(sudo apt-get -qq -y install "${PACKAGE_NAME}")

# Callers download only this file. Keep the helper inline so install, version,
# and lint share one script. The pipeline appends each source path to lint.
ANALYZE_PS1="$(mktemp "${TMPDIR:-/tmp}/powershell-linter.XXXXXX")"
# shellcheck disable=SC2064 # path is fixed at startup; expand it when the trap is set
trap "rm -f $(printf '%q' "${ANALYZE_PS1}")" EXIT
cat > "${ANALYZE_PS1}" <<'PS1'
#Requires -Version 7.0
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('version', 'install', 'lint')]
    [string] $Action,

    [Parameter(Position = 1)]
    [string] $Path
)

$ErrorActionPreference = 'Stop'
$MinimumVersion = [version] '1.25.0'

function Get-InstalledVersion {
    $best = $null
    foreach ($module in @(Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
        if ($module.Version -ge $MinimumVersion -and ($null -eq $best -or $module.Version -gt $best)) {
            $best = $module.Version
        }
    }
    return $best
}

function Find-SettingsFile {
    param(
        [string] $StartFile,
        [string] $ScanRoot
    )

    if ($env:PSSA_SETTINGS) {
        return $env:PSSA_SETTINGS
    }

    $dir = Split-Path -Parent (Resolve-Path -LiteralPath $StartFile).Path
    $stop = (Resolve-Path -LiteralPath $ScanRoot).Path

    while ($dir) {
        $candidate = Join-Path $dir 'PSScriptAnalyzerSettings.psd1'
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
        if ($dir -eq $stop) {
            break
        }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) {
            break
        }
        $dir = $parent
    }

    return $null
}

switch ($Action) {
    'version' {
        $installed = Get-InstalledVersion
        if ($null -eq $installed) { exit 1 }
        $installed.ToString()
        exit 0
    }
    'install' {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Install-Module -Name PSScriptAnalyzer -RequiredVersion $MinimumVersion -Scope CurrentUser -Force
        exit 0
    }
    'lint' {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            Write-Error 'lint requires a path.'
            exit 1
        }

        $resolved = (Resolve-Path -LiteralPath $Path).Path
        $tokens = $null
        $parseErrors = $null
        [void] [System.Management.Automation.Language.Parser]::ParseFile(
            $resolved,
            [ref] $tokens,
            [ref] $parseErrors
        )
        $blocking = 0
        foreach ($parseError in @($parseErrors)) {
            '{0}:{1}:{2}: [Error] ParseError: {3}' -f @(
                $resolved,
                $parseError.Extent.StartLineNumber,
                $parseError.Extent.StartColumnNumber,
                $parseError.Message
            )
            $blocking++
        }

        # The settings file is configuration, not a script under review.
        if ((Split-Path -Leaf $resolved) -eq 'PSScriptAnalyzerSettings.psd1') {
            if ($blocking -gt 0) { exit 1 }
            exit 0
        }

        Import-Module PSScriptAnalyzer -MinimumVersion $MinimumVersion

        $scanRoot = $env:SCAN_ROOT
        if ([string]::IsNullOrWhiteSpace($scanRoot)) {
            $scanRoot = (Get-Location).Path
        }

        $invoke = @{ Path = $resolved }
        $settings = Find-SettingsFile -StartFile $resolved -ScanRoot $scanRoot
        if ($settings) {
            $invoke.Settings = $settings
        } else {
            $invoke.Severity = @('Error', 'Warning')
        }

        $issues = @(Invoke-ScriptAnalyzer @invoke)
        foreach ($item in $issues) {
            $severity = [string] $item.Severity
            '{0}:{1}:{2}: [{3}] {4}: {5}' -f @(
                $item.ScriptPath,
                $item.Line,
                $item.Column,
                $severity,
                $item.RuleName,
                $item.Message
            )
            if ($severity -in @('Error', 'Warning')) {
                $blocking++
            }
        }
        if ($blocking -gt 0) { exit 1 }
        exit 0
    }
}
PS1

PREREQUISITE_COMMANDS=(pwsh)
PACKAGE_NAME='PSScriptAnalyzer'
BASE_COMMAND="${PACKAGE_NAME}"
INSTALLED_CHECK=(pwsh -NoProfile -NonInteractive -File "${ANALYZE_PS1}" version)
INSTALL_COMMAND=(pwsh -NoProfile -NonInteractive -File "${ANALYZE_PS1}" install)
TEST_COMMAND=(pwsh -NoProfile -NonInteractive -File "${ANALYZE_PS1}" lint)
EXTRA_PARAMETERS=()
REDIRECTED=false
VERSION_COMMAND=("${INSTALLED_CHECK[@]}")
BANNER_NAME="${BASE_COMMAND}"

# --- Discovery -------------------------------------------------------------------
# file(1) does not identify PowerShell sources, so match extensions only.
FILE_TYPE_SEARCH_PATTERN=''
FILE_NAME_SEARCH_PATTERN='\.(ps1|psm1|psd1)$'
# Env SCAN_ROOT overrides the default when set by the caller/CI.
SCAN_ROOT="${SCAN_ROOT:-.}"
export SCAN_ROOT

# ==================================================================================
# PARAMETER TABLES — extend for tool-specific runtime knobs
# ==================================================================================

# Boolean parameters and their default values.
declare -A BOOL_PARAMS=(
    ["REPORT_ONLY"]=false
    ["SHOW_ERRORS"]=true
    ["SHOW_FILTERED"]=false
    ["SHOW_UNMATCHED"]=false
)

# Comma-separated parameters that should be converted into arrays / lists.
LIST_PARAMS=("INCLUDE_FILES" "EXCLUDE_FILES")

# Parameters where the default is '' and should be set if provided.
SET_IF_PROVIDED_PARAMS=()

# Associative array where the default is overwritten if a matching name is found.
declare -A NAMED_VALUE_PARAMS=(
)

# -------------------------------------------------------------------------------- #
#                    Global Variables for required configuration                   #
# -------------------------------------------------------------------------------- #
# The following are configuration items that MUST exist & have a non empty value.  #
# if the value is unset or empty the script will error and abort.                  #
#                                                                                  #
# With REQUIRED_DIRECTORIES, any listed directory must also exist.                 #
# -------------------------------------------------------------------------------- #

REQUIRED_VARIABLES=("PACKAGE_NAME" "BASE_COMMAND")
REQUIRED_ARRAYS=()
REQUIRED_DIRECTORIES=("SCAN_ROOT")

# -------------------------------------------------------------------------------- #
#                         Script Specific Global Variables                         #
# -------------------------------------------------------------------------------- #

#
# Add any script specific custom global variables here.
#

# -------------------------------------------------------------------------------- #
# Function: handle_non_standard_parameters()                                       #
# Description: Handles additional or non-standard parameters if enabled.           #
#              Stores any extra parameters in a global buffer for later use.       #
# Returns:                                                                         #
#   1 - If non-standard parameters are disabled.                                   #
#   0 - If parameters are processed successfully.                                  #
# -------------------------------------------------------------------------------- #

handle_non_standard_parameters()
{
    local parameters=false
    local extra_params=""
    declare -g PARAMETERS_BUFFER=""

    # Tool authors: set parameters=true and populate extra_params / PARAMETERS_BUFFER
    # when handling custom env vars (e.g. FLAGS, WHITELIST).

    if [[ "${parameters}" == false ]]; then
        return 1
    fi

    if [[ -n "${extra_params}" ]]; then
        local -a temp_array=()
        read -r -a temp_array <<< "${extra_params}"
        EXTRA_PARAMETERS+=("${temp_array[@]}")
    fi
    return 0
}

# -------------------------------------------------------------------------------- #
#                                     STOP HERE                                    #
# -------------------------------------------------------------------------------- #
# Everything below here is standard and designed to work with all of the tools     #
# that have been built and released as part of the CICDToolbox.                    #
# -------------------------------------------------------------------------------- #

# Used to track the exit state based on test results within the script.
EXIT_VALUE=0
CURRENT_STAGE=0

# -------------------------------------------------------------------------------- #
# Function: stage()                                                                #
# Description: Advances the stage counter and draws a Stage N heading.             #
# Parameters:                                                                      #
#   $1 - (Optional) Stage title message.                                           #
# -------------------------------------------------------------------------------- #

stage()
{
    local message=${1:-}

    CURRENT_STAGE=$((CURRENT_STAGE + 1))
    draw_line "Stage ${CURRENT_STAGE}: ${message}"
}

# -------------------------------------------------------------------------------- #
# Function: passed()                                                               #
# Description: Increments the passed test count and prints a success message       #
#              with a green tick.                                                  #
# Parameters:                                                                      #
#   $1 - (Optional) Message to display alongside the success indicator.            #
# -------------------------------------------------------------------------------- #

passed()
{
    local message=${1:-}

    passed_count=$((passed_count + 1))

    echo " [ ${bold_green_text}✅${reset} ] ${message}"
}

# -------------------------------------------------------------------------------- #
# Function: failed()                                                               #
# Description: Increments the failed test count and prints a failure message       #
#              with a red cross. Optionally displays error details if enabled.     #
# Parameters:                                                                      #
#   $1 - (Optional) Message to display alongside the failure indicator.            #
#   $2 - (Optional) Errors to display if SHOW_ERRORS is enabled.                   #
# -------------------------------------------------------------------------------- #

failed()
{
    local message=${1:-}
    local errors=${2:-}

    failed_count=$((failed_count + 1))

    echo " [ ${bold_red_text}❌${reset} ] ${message}"

    # shellcheck disable=SC2154
    if [[ "${SHOW_ERRORS}" == true ]]; then
        if [[ -n "${errors}" ]]; then
            echo
            echo "${errors}" | while IFS= read -r err; do
                echo "          ${err}"
            done
            echo
        fi
    fi

    # Set exit value to indicate failure.
    EXIT_VALUE=1
}

# -------------------------------------------------------------------------------- #
# Function: filtered()                                                             #
# Description: Increments the filtered count and optionally prints a message       #
#              with a yellow indicator if SHOW_FILTERED is enabled.                #
# Parameters:                                                                      #
#   $1 - (Optional) Message to display alongside the filtered indicator.           #
# -------------------------------------------------------------------------------- #

filtered()
{
    local message=${1:-}

    filtered_count=$((filtered_count + 1))

    # shellcheck disable=SC2154
    if [[ "${SHOW_FILTERED}" == true ]]; then
        echo " [ ${bold_yellow_text}🟡${reset} ] ${message}"
    fi
}

# -------------------------------------------------------------------------------- #
# Function: unmatched()                                                            #
# Description: Increments the unmatched count and optionally prints a message      #
#              with a blue indicator if SHOW_UNMATCHED is enabled.                 #
# Parameters:                                                                      #
#   $1 - (Optional) Message to display alongside the unmatched indicator.          #
# -------------------------------------------------------------------------------- #

unmatched()
{
    local message=${1:-}

    unmatched_count=$((unmatched_count + 1))

    # shellcheck disable=SC2154
    if [[ "${SHOW_UNMATCHED}" == true ]]; then
        echo " [ ${bold_cyan_text}🔵${reset} ] ${message}"
    fi
}

# -------------------------------------------------------------------------------- #
# Function: is_in_list()                                                           #
# Description: Checks if a given string (needle) matches any pattern in a list.    #
#              Uses regex matching to determine if the needle is in the array.     #
# Parameters:                                                                      #
#   $1 - The string to search for (needle).                                        #
#   $@ - The list of patterns to match against.                                    #
# Returns:                                                                         #
#   0 - If a match is found.                                                       #
#   1 - If no match is found.                                                      #
# -------------------------------------------------------------------------------- #

is_in_list()
{
    local needle=$1
    shift
    local array=("$@")

    # Iterate over the list and check if the needle matches any pattern.
    for pattern in "${array[@]}"; do
        if [[ "${needle}" =~ ${pattern} ]]; then
            return 0    # Match found.
        fi
    done
    return 1            # No match found.
}

# -------------------------------------------------------------------------------- #
# Function: is_excluded()                                                          #
# Description: Checks if a given file or item is in the exclusion list.            #
#              Uses is_in_list() to determine if the needle is excluded.           #
# Parameters:                                                                      #
#   $1 - The item to check against the exclusion list.                             #
# Returns:                                                                         #
#   0 - If the item is in the exclusion list.                                      #
#   1 - If the item is not excluded.                                               #
# -------------------------------------------------------------------------------- #

is_excluded()
{
    local needle=$1

    # shellcheck disable=SC2154
    if is_in_list "${needle}" "${EXCLUDE_FILES[@]}"; then
        return 0    # Item is excluded.
    fi
    return 1        # Item is not excluded.
}

# -------------------------------------------------------------------------------- #
# Function: is_included()                                                          #
# Description: Checks if a given file or item is in the inclusion list.            #
#              Uses is_in_list() to determine if the needle is included.           #
# Parameters:                                                                      #
#   $1 - The item to check against the inclusion list.                             #
# Returns:                                                                         #
#   0 - If the item is in the inclusion list.                                      #
#   1 - If the item is not included.                                               #
# -------------------------------------------------------------------------------- #

is_included()
{
    local needle=$1

    # shellcheck disable=SC2154
    if is_in_list "${needle}" "${INCLUDE_FILES[@]}"; then
        return 0    # Item is included.
    fi
    return 1        # Item is not included.
}

# -------------------------------------------------------------------------------- #
# Function: draw_line()                                                            #
# Description: Draws a formatted line with an optional right aligned message.      #
#              The line adjusts to fit the screen width, with customizable         #
#              offset on the right. Uses bold cyan text for the message.           #
# Parameters:                                                                      #
#   $1 - (Optional) Message to display in the center of the line.                  #
#   $2 - (Optional) Offset width for the right side (default: 2).                  #
# -------------------------------------------------------------------------------- #

draw_line()
{
    local message=${1:-}
    local offset=${2:-2}
    local width=${screen_width}

    # Get length of the message.
    local textsize=${#message}

    # Define line characters and calculate left/right line widths.
    local left_line='-' left_width=$((width - (textsize + offset + 2)))
    local right_line='-' right_width=${offset}

    # Extend the left and right lines to match the required widths.
    while ((${#left_line} < left_width)); do left_line+="${left_line}"; done
    while ((${#right_line} < right_width)); do right_line+="${right_line}"; done

    # Print formatted line with message centred and cyan color.
    printf '%s %s %s\n' "${left_line:0:left_width}" "${bold_cyan_text}${message}${reset}" "${right_line:0:right_width}"
}

# -------------------------------------------------------------------------------- #
# Function: run_command()                                                          #
# Description: Executes a given command, supporting both standalone arguments      #
#              and array references. Captures and returns output, handling errors. #
# Parameters:                                                                      #
#   $@ - Command and its arguments (supports array expansion via '@' notation).    #
# Returns:                                                                         #
#   0 - If the command executes successfully.                                      #
#   1 - If the command fails (error message is displayed if DEBUG_MODE is true).   #
# -------------------------------------------------------------------------------- #

run_command()
{
    local output
    local -a command=()

    # Flatten all input arguments (arrays + standalone strings).
    for arg in "$@"; do
        if [[ -n "${arg}" ]]; then
            if [[ "${arg}" =~ ^[[:alnum:]_]+[@]$ ]]; then
                # Handle array references like $list1[@].

                # Remove '@' and get reference to the array.
                local -n ref_array="${arg%@}"
                # Append referenced array elements.
                command+=("${ref_array[@]}")
            else
                # Treat it as a standalone string argument.
                command+=("${arg}")
            fi
        fi
    done

    # Execute the command and capture output, handling errors.
    if ! output=$("${command[@]}" 2>&1); then
        if [[ "${DEBUG_MODE}" == true ]]; then
            # Display detailed error message in debug mode.
            echo " [ ${bold_red_text}Command Error${reset} ]" >&2
            echo "              Command = ${command[*]}" >&2
            echo "              Result = ${output}" >&2
        else
            # Show command output in non-debug mode.
            echo "${output}"
        fi
        return 1    # Indicate failure.
    fi

    # Print successful command output.
    echo "${output}"
    return 0        # Indicate success.
}

# -------------------------------------------------------------------------------- #
# Function: handle_prerequisites()                                                 #
# Description: Ensures all prerequisite commands and dependencies are installed.   #
#              Checks for required binaries, updates pip if needed, verifies       #
#              module installation, and installs dependencies from requirements    #
#              files.                                                              #
# Returns:                                                                         #
#   Exits the script if any prerequisite checks fail.                              #
# -------------------------------------------------------------------------------- #

handle_prerequisites()
{
    local errors
    local errors_found=0
    local buffer=""
    local prefix=" [ ${bold_red_text}Prerequisite Error${reset} ]"
    local suffix="[${bold_cyan_text}Enable DEBUG_MODE for more details${reset}]"
    local ok_prefix=" [ ${bold_green_text}OK${reset} ]"

    stage 'Install Prerequisites'

    # Ensure all prerequisite commands are installed.
    for i in "${PREREQUISITE_COMMANDS[@]}"; do
        if ! errors=$(run_command command -v "${i}"); then
            buffer+="${prefix} ${i} is not installed - Aborting! ${suffix}\n"
            ((errors_found++))
        fi
    done

    # Optionally update pip if enabled.
    if [[ "${UPDATE_PIP}" = true ]]; then
        if ! errors=$(run_command python3 -m pip install --quiet --upgrade pip); then
            buffer+="${prefix} Pip update failed - Aborting ${suffix}\n"
            ((errors_found++))
        else
            echo "${ok_prefix} python3 -m pip install --quiet --upgrade pip"
        fi
    fi

    # Empty INSTALLED_CHECK => always install/upgrade when INSTALL_COMMAND is set.
    # Non-empty INSTALLED_CHECK => install only if the check fails.
    # Empty INSTALL_COMMAND => skip install (builtin / preinstalled tools).
    if [[ ${#INSTALL_COMMAND[@]} -gt 0 ]]; then
        local need_install=false
        if [[ ${#INSTALLED_CHECK[@]} -eq 0 ]]; then
            need_install=true
        elif ! errors=$(run_command "${INSTALLED_CHECK[@]}"); then
            need_install=true
        fi

        if [[ "${need_install}" == true ]]; then
            if ! errors=$(run_command "${INSTALL_COMMAND[@]}"); then
                buffer+="${prefix} Failed to install ${BANNER_NAME} ${suffix}\n"
                ((errors_found++))
            else
                echo "${ok_prefix} ${INSTALL_COMMAND[*]}"
            fi
        else
            echo "${ok_prefix} ${BASE_COMMAND} is already installed"
        fi
    fi

    # Install dependencies from repository requirements files if enabled.
    if [[ "${INSTALL_REQUIREMENTS_FROM_REPO}" = true ]]; then
        while IFS= read -r filename; do
            if ! errors=$(run_command pip install -r "${filename}"); then
                buffer+="${prefix} ${filename} ${suffix}\n"
                ((errors_found++))
            else
                echo "${ok_prefix} pip install -r ${filename}"
            fi
        done < <(find . -name 'requirements*.txt' -type f -not -path '*/.git/*' | sed 's|^\./||' | sort -Vf || true)
    fi

    # If errors were found, print them and exit with failure status.
    if (( errors_found > 0 )); then
        printf "%b" "${buffer}" >&2
        exit 1
    fi
}

# -------------------------------------------------------------------------------- #
# Function: get_version_information()                                              #
# Description: Retrieves and extracts the version number from the output of        #
#              a specified command. Formats the version into a banner string.      #
# Globals Modified:                                                                #
#   BANNER - Stores the formatted version banner.                                  #
# -------------------------------------------------------------------------------- #

get_version_information()
{
    local output VERSION

    # Run the version command and capture output, removing newlines.
    if ! output=$(run_command "${VERSION_COMMAND[@]}" | tr -d '\n' | head -n 1); then
        # Default to "Unknown" if command fails.
        VERSION="Unknown"
    else
        # Extract numeric version from output using regex.
        VERSION="$(sed -E 's/[^0-9.]*([0-9.]+).*/\1/' <<<"${output}")"
    fi

    # Construct and store the version banner (shown as Stage 3).
    BANNER="Run ${BANNER_NAME} (v${VERSION})"
}

# -------------------------------------------------------------------------------- #
# Function: check_file()                                                           #
# Description: Runs a test command on a specified file, handling redirection if    #
#              required. Increments the file count and records pass/fail results   #
#              accordingly.                                                        #
# Parameters:                                                                      #
#   $1 - Filename to be checked.                                                   #
# -------------------------------------------------------------------------------- #

check_file()
{
    local filename=$1
    local errors

    file_count=$((file_count + 1))

    if [[ "${REDIRECTED}" == true ]]; then
        # Real stdin redirection — do not pass "<" as an argument.
        if ! errors=$("${TEST_COMMAND[@]}" "${EXTRA_PARAMETERS[@]}" < "${filename}" 2>&1); then
            failed "${filename}" "${errors}"
        else
            passed "${filename}"
        fi
    else
        local command=("${TEST_COMMAND[@]}" "${EXTRA_PARAMETERS[@]}" "${filename}")
        if ! errors=$(run_command "${command[@]}"); then
            failed "${filename}" "${errors}"
        else
            passed "${filename}"
        fi
    fi
}

# -------------------------------------------------------------------------------- #
# Function: scan_files()                                                           #
# Description: Iterates through files in the specified scan directory, applying    #
#              inclusion/exclusion rules, file type and name patterns, and         #
#              checking files accordingly. Unmatched files are recorded.           #
# -------------------------------------------------------------------------------- #

scan_files()
{
    # Read filenames from the find command output.
    while IFS= read -r filename; do
        # Check if the file is explicitly included.
        if is_included "${filename}"; then
            check_file "${filename}"
        # Check if the file is explicitly excluded.
        elif is_excluded "${filename}"; then
            filtered "${filename}"
        # Check if the file matches the specified type pattern.
        elif [[ -n "${FILE_TYPE_SEARCH_PATTERN}" ]] && file -b "${filename}" | grep -qE "${FILE_TYPE_SEARCH_PATTERN}"; then
            check_file "${filename}"
        # Check if the file matches the specified name pattern.
        elif [[ -n "${FILE_NAME_SEARCH_PATTERN}" ]] && [[ "${filename}" =~ ${FILE_NAME_SEARCH_PATTERN} ]]; then
            check_file "${filename}"
        # Mark the file as unmatched if it doesn't fit any criteria.
        else
            unmatched "${filename}"
        fi
    done < <(find "${SCAN_ROOT}" -type f -not -path '*/.git/*' | sed 's|^\./||' | sort -Vf || true)
}

# -------------------------------------------------------------------------------- #
# Function: handle_parameters()                                                    #
# Description: Processes various types of script parameters, including boolean,    #
#              list-based, named-value, and set-if-provided parameters. Ensures    #
#              global variables are properly set and detects non-standard          #
#              parameters for additional handling.                                 #
# -------------------------------------------------------------------------------- #

handle_parameters()
{
    local parameters=false
    local buffer=""

    stage "Parameters"

    # Check and apply boolean parameters.
    for param in "${!BOOL_PARAMS[@]}"; do
        if [[ -n "${!param-}" ]]; then
            # Assign user-defined value.
            declare -g "${param}=${!param}"
        else
            # Assign default value
            declare -g "${param}=${BOOL_PARAMS[${param}]}"
        fi

        # Track and format changed boolean parameters.
        if [[ "${!param}" != "${BOOL_PARAMS[${param}]}" ]]; then
            buffer+=" ${param}: ${bold_cyan_text}${!param}${reset}\n"
            parameters=true
        fi
    done

    # Process each list parameter dynamically. Uses a nameref instead of eval so
    # user-supplied values can never be interpreted as shell commands.
    for list_param in "${LIST_PARAMS[@]}"; do
        local -n array_ref="${list_param}"
        local var_value="${!list_param-}"

        # Reset the target array, then populate it from the comma-separated value.
        array_ref=()
        if [[ -n "${var_value}" ]]; then
            IFS=',' read -r -a array_ref <<< "${var_value}"
        fi

        # If list is populated, add to buffer.
        if (( ${#array_ref[@]} > 0 )); then
            buffer+=" ${list_param}: ${bold_cyan_text}${!list_param}${reset}\n"
            parameters=true
        fi
    done

    # Process parameters that should be set if provided (otherwise default to '').
    for param in "${SET_IF_PROVIDED_PARAMS[@]}"; do
        if [[ -n "${!param-}" ]]; then
            # Assign user-defined value.
            declare -g "${param}=${!param}"
            buffer+=" ${param}: ${bold_cyan_text}${!param}${reset}\n"
            parameters=true
        else
            # Default to an empty string.
            declare -g "${param}=''"
        fi
    done

    # Process named value parameters and overwrite if different from default.
    for param in "${!NAMED_VALUE_PARAMS[@]}"; do
        local default_value="${NAMED_VALUE_PARAMS[${param}]}"

        if [[ -n "${!param-}" && "${!param}" != "${default_value}" ]]; then
            declare -g "${param}=${!param}"
        else
            declare -g "${param}=${default_value}"
        fi

        # Track and format changed named value parameters.
        if [[ "${!param}" != "${default_value}" ]]; then
            buffer+=" ${param}: ${bold_cyan_text}${!param}${reset}\n"
            parameters=true
        fi
    done

    # Handle non-standard parameters if applicable.
    if handle_non_standard_parameters; then
        buffer+=${PARAMETERS_BUFFER}
        parameters=true
    fi

    # Display parameter changes, or an explicit empty-state message.
    if [[ "${parameters}" == true ]]; then
        printf "%b" "${buffer}"
    else
        echo " No parameters given"
    fi
}

# -------------------------------------------------------------------------------- #
# Function: footer()                                                               #
# Description: Prints a summary report of the script execution, displaying counts  #
#              for total files processed, passed, failed, filtered, and unmatched  #
#              files.                                                              #
# -------------------------------------------------------------------------------- #

footer()
{
    stage 'Report'

    # Define an array of status labels and their corresponding counts.
    local stats=(
        "${bold_white_text}Total${reset}: ${file_count}"
        "${bold_green_text}Passed${reset}: ${passed_count}"
        "${bold_red_text}Failed${reset}: ${failed_count}"
        "${bold_yellow_text}Filtered${reset}: ${filtered_count}"
        "${bold_cyan_text}Unmatched${reset}: ${unmatched_count}"
    )

    # Print all collected statistics in a single formatted line.
    echo " ${stats[*]}"

    stage 'Complete'
}

# -------------------------------------------------------------------------------- #
# Function: handle_color_parameters()                                              #
# Description: Ensures the NO_COLOR variable is properly set to a boolean value.   #
#              Defaults to false if not explicitly set.                            #
# -------------------------------------------------------------------------------- #

handle_color_parameters()
{
    # Default to false if NO_COLOR is not set.
    NO_COLOR=${NO_COLOR:-false}

    # Ensure NO_COLOR is strictly a boolean value (true or false).
    NO_COLOR=$([[ "${NO_COLOR}" == true ]] && echo true || echo false)
}

# -------------------------------------------------------------------------------- #
# Function: setup()                                                                #
# Description: Initializes terminal settings, screen width, and color variables.   #
#              Ensures 'tput' is available before using it and sets a default      #
#              screen width if unavailable.                                        #
# -------------------------------------------------------------------------------- #

setup()
{
    export TERM=xterm

    handle_color_parameters

    # Declare global variables explicitly.
    declare -g screen_width
    declare -g bold_red_text bold_green_text bold_yellow_text bold_cyan_text bold_white_text reset
    declare -g file_count passed_count failed_count filtered_count unmatched_count

    # Initialize variables with default values.
    screen_width=0
    bold_red_text=''
    bold_green_text=''
    bold_yellow_text=''
    bold_cyan_text=''
    bold_white_text=''
    reset=''
    file_count=0
    passed_count=0
    failed_count=0
    filtered_count=0
    unmatched_count=0

    # Check if 'tput' is available before using it.
    if ! command -v tput &>/dev/null; then
        echo "Error: 'tput' command not found. Terminal capabilities may be limited." >&2
        # Set a default safe width.
        screen_width=140
        return
    fi

    # Get the terminal width and adjust it.
    screen_width=$(tput cols)
    screen_width=$((screen_width - 2))
    # Ensure minimum width.
    (( screen_width < 140 )) && screen_width=140

    # Set color formatting variables if NO_COLOR is disabled.
    if [[ "${NO_COLOR}" == false ]]; then
        bold_red_text=$(tput bold; tput setaf 1)
        bold_green_text=$(tput bold; tput setaf 2)
        bold_yellow_text=$(tput bold; tput setaf 3)
        bold_cyan_text=$(tput bold; tput setaf 6)
        bold_white_text=$(tput bold; tput setaf 7)
        reset=$(tput sgr0)
    fi
}

# -------------------------------------------------------------------------------- #
# Function: check_configuration()                                                  #
# Description: Validates required configuration variables, arrays, and             #
#              directories. Ensures all necessary settings are properly defined    #
#              #before execution.                                                  #
# Returns:                                                                         #
#   Exits the script if any configuration errors are found.                        #
# -------------------------------------------------------------------------------- #

check_configuration()
{
    local errors_found=0
    local config_buffer=""
    local prefix=" [ ${bold_red_text}Config Error${reset} ]"

    # Check required string variables.
    for var in "${REQUIRED_VARIABLES[@]}"; do
        # Use ${!var-} to avoid unbound variable errors.
        if [[ -z "${!var-}" ]]; then
            config_buffer+="${prefix} ${var} is not set.\n"
            ((errors_found++))
        fi
    done

    # Check required array variables (ensure they exist and are not empty).
    for arr in "${REQUIRED_ARRAYS[@]}"; do
        if ! declare -p "${arr}" &>/dev/null; then
            config_buffer+="${prefix} ${arr} is not set.\n"
            ((errors_found++))
            continue  # Skip further checks if the array is not set.
        fi

        # Get the length of the array safely.
        local arr_length
        arr_length=$(eval "echo \${#${arr}[@]}")

        if (( arr_length == 0 )); then
            config_buffer+="${prefix} ${arr} is empty.\n"
            ((errors_found++))
        fi
    done

    # Check required directory variables (ensure directories exist).
    for dir in "${REQUIRED_DIRECTORIES[@]}"; do
        if [[ ! -d "${!dir-}" ]]; then
            config_buffer+="${prefix} Check ${dir} settings as ${!dir-} does not exist.\n"
            ((errors_found++))
        fi
    done

    # If any errors were found, print them and exit with failure status.
    if (( errors_found > 0 )); then
        printf "%b" "${config_buffer}" >&2
        exit 1
    fi
}

# -------------------------------------------------------------------------------- #
# Function: check_bash_version()                                                   #
# Description: Ensures the script is running on a compatible Bash version.         #
#              Compares the current Bash version against the required minimum      #
#              version.                                                            #
# Returns:                                                                         #
#   Exits the script if the Bash version is older than the required version.       #
# -------------------------------------------------------------------------------- #

check_bash_version()
{
    local required_version="4.4.0"
    local current_version
    local sorted_versions

    # Extract only the numeric part (major.minor.patch) from BASH_VERSION.
    current_version=$(echo "${BASH_VERSION}" | sed -E 's/[^0-9.]*([0-9.]+).*/\1/')

    # Compare versions by sorting them and taking the smallest value.
    sorted_versions=$(printf '%s\n' "${required_version}" "${current_version}" | sort -V | head -n1)

    # If the sorted first version isn't the required version, the Bash version is outdated.
    if [[ "${sorted_versions}" != "${required_version}" ]]; then
        echo "[ ${bold_red_text}Version Error${reset} ] Bash version ${current_version} is too old. Require ${required_version} or newer." >&2
        # Exit with an error if the Bash version is too old.
        exit 1
    fi
}

# -------------------------------------------------------------------------------- #
#                                       Main                                       #
# -------------------------------------------------------------------------------- #

main() {
    setup                       # Initialize terminal settings, colours, and global variables.
    check_bash_version          # Ensure the script is running on a compatible Bash version.
    check_configuration         # Validate required configuration variables and directories.
    handle_parameters           # Stage 1: process script parameters and update global settings.
    handle_prerequisites        # Stage 2: ensure required commands and dependencies are installed.
    get_version_information     # Retrieve and format version information.
    stage "${BANNER}"           # Stage 3: display the run banner with version info.
    scan_files                  # Scan files and process them based on inclusion/exclusion rules.
    footer                      # Stages 4–5: report summary and complete.

    # Override exit value if REPORT_ONLY is enabled.
    # shellcheck disable=SC2154
    [[ "${REPORT_ONLY}" == true ]] && EXIT_VALUE=0 

    exit "${EXIT_VALUE}"        # Exit with the final status code.
}

main

# -------------------------------------------------------------------------------- #
#                                  END OF SCRIPT!                                  #
# -------------------------------------------------------------------------------- #
