#  PowerShell Script for Silent Winget Updates via TRMM
#  by rellek (JVKeller)
#  ----------------------------------------------------
#  This script is designed to run as SYSTEM. It will:
#  1. Create a log file in the tactical agent directory.
#  2. Locate the winget.exe executable.
#  3. Attempt to self-update winget to the latest version.
#  4. Update winget sources.
#  5. Fetch all available upgrades, filter exclusions.
#  6. Upgrade remaining applications one-by-one.
#  7. Log all output and a final summary report to a transcript file.
#  ----------------------------------------------------
#  Arguments: 
#       -ExcludeMicrosoft
#       -ForceUpgrade
#       -IncludeUnknown
#       -Exclusions inkscape.inscape, mozilla.firefox
#  ----------------------------------------------------
#  What doesn't work:
#  Upgrade that requite to be uninstalled before reinstalling. i.e. Major updagrade.

param (
    # If specified, the script will exclude common Microsoft products (like Edge, .NET, etc.).
    [switch]$ExcludeMicrosoft,

    # If specified, passes the '--force' argument to 'winget upgrade', which can help reinstall broken packages.
    [switch]$ForceUpgrade,
    
    # If specified, passes the '--include-unknown' argument to 'winget upgrade'.
    [switch]$IncludeUnknown,

    # A comma-separated list of package IDs to exclude from updates.
    [string[]]$Exclusions = @()
)

# --- Configuration ---
$LogPath = "C:\\ProgramData\\TacticalRMM\\logs"
$LogFile = Join-Path $LogPath "winget-updates-$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
# --- End Configuration ---

# Function to write messages to both console and transcript
function Write-Log {
    param(
        [string]$Message
    )
    # This ensures the message appears in the TRMM logs and the transcript file
    Write-Host $Message
}

# Function to find the winget executable
function Find-WingetExe {
    Write-Log "INFO: Attempting to locate winget.exe..."
    
    # 1. Check the standard location for App Execution Aliases for the SYSTEM profile
    $systemProfileWinget = Join-Path $env:SystemRoot "System32\config\systemprofile\AppData\Local\Microsoft\WindowsApps\winget.exe"
    if (Test-Path $systemProfileWinget) {
        Write-Log "SUCCESS: Found winget.exe at the default SYSTEM user profile path: $systemProfileWinget"
        return $systemProfileWinget
    }
    Write-Log "INFO: winget.exe not found at the default SYSTEM profile path."

    # 2. If not found, try to resolve it from the AppX package information across all users.
    # This is more reliable as it finds the actual installation directory, which SYSTEM can access.
    try {
        $package = Get-AppxPackage -Name "Microsoft.DesktopAppInstaller" -AllUsers -ErrorAction Stop | Select-Object -First 1
        if ($package) {
            $wingetPathInPackage = Join-Path $package.InstallLocation "winget.exe"
            if (Test-Path $wingetPathInPackage) {
                Write-Log "SUCCESS: Found winget.exe via AppxPackage (AllUsers) at: $wingetPathInPackage"
                return $wingetPathInPackage
            }
        }
    } catch {
        Write-Log "WARN: Could not query AppxPackage for 'Microsoft.DesktopAppInstaller'. This might be an older system or winget is not installed."
        Write-Log "Exception: $($_.Exception.Message)"
    }
    Write-Log "INFO: Could not find winget.exe via AppxPackage."

    # 3. As a last resort, check if 'winget.exe' is in the system PATH
    # This can be unreliable as it might point to a user-specific path that SYSTEM cannot access.
    $wingetInPath = Get-Command "winget.exe" -ErrorAction SilentlyContinue
    if ($wingetInPath) {
        Write-Log "SUCCESS: Found winget.exe in the system PATH: $($wingetInPath.Source)"
        Write-Log "WARN: Using winget from PATH. This might fail if the path is in a user profile inaccessible to the SYSTEM account."
        return "winget.exe" # Return the command name to be executed directly
    }
    
    Write-Log "ERROR: All methods to find winget.exe failed."
    return $null
}

# Ensure the log directory exists
if (-not (Test-Path $LogPath -PathType Container)) {
    try {
        New-Item -Path $LogPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        Write-Host "Successfully created log directory at $LogPath"
    } catch {
        Write-Host "FATAL: Could not create log directory at $LogPath. Exiting."
        exit 1
    }
}

# Start writing all output to the log file
try {
    Start-Transcript -Path $LogFile -ErrorAction Stop
} catch {
    Write-Host "FATAL: Could not start transcript at $LogFile. Check permissions. Exiting."
    exit 1
}

Write-Log "=================================================="
Write-Log "Starting Winget Upgrade Script at $(Get-Date)"
Write-Log "Log file will be saved to: $LogFile"
Write-Log "=================================================="

# Find winget.exe using our robust function
$wingetPath = Find-WingetExe

if (-not $wingetPath) {
    Write-Log "FATAL: winget.exe could not be located. The script cannot continue. Please ensure the 'App Installer' from the Microsoft Store is installed and updated."
    Stop-Transcript
    exit 1
}

# Set output encoding to UTF-8 to prevent character corruption when parsing winget's output.
$OutputEncoding = [System.Text.Encoding]::UTF8

try {
    Write-Log "[STEP 1/4] Checking winget version..."
    $versionOutput = & "$wingetPath" --version
    $wingetVersionString = ($versionOutput | Out-String).Trim()
    $wingetVersion = [version]"0.0.0" # Default to a low version for safety

    try {
        # Attempt to parse a version string like 'v1.7.10911' or '1.8.0'
        if ($wingetVersionString -match 'v?((?:\\d+\\.)*\\d+)') {
            $versionString = $matches[1]
            # The [version] constructor can fail on versions with more than 4 parts (e.g., from dev builds).
            # We'll safely take up to the first 4 parts to prevent script errors.
            $safeVersionString = ($versionString.Split('.')[0..3]) -join '.'
            $wingetVersion = [version]$safeVersionString
        } else {
             # Fallback for any other unusual version formats
             $wingetVersion = [version]$wingetVersionString
        }
        Write-Log "INFO: Detected winget version: $($wingetVersion.ToString())"
    } catch {
        Write-Log "WARN: Could not parse winget version string: '$wingetVersionString'."
        # $wingetVersion remains at its default of 0.0.0
    }

    Write-Log "[STEP 2/4] Attempting to upgrade winget client..."
    try {
        # Specifically use the 'msstore' source as it's the official channel for the App Installer/winget.
        & "$wingetPath" upgrade Microsoft.DesktopAppInstaller --source msstore --accept-package-agreements --silent
        $exitCode = $LASTEXITCODE
        
        # A success code (0), reboot required (1641), or another success reboot code (3010) are all considered successful executions.
        if ($exitCode -eq 0 -or $exitCode -eq 1641 -or $exitCode -eq 3010) {
            Write-Log "INFO: Winget self-update command completed. Re-locating executable to ensure we use the newest version."
            
            # The path to winget might have changed after an update, so we MUST find it again.
            $originalPath = $wingetPath
            $wingetPath = Find-WingetExe
            
            if (-not $wingetPath) {
                Write-Log "FATAL: winget.exe could not be located after self-update attempt. Script cannot continue."
                Stop-Transcript
                exit 1
            }
            
            # Only re-check the version if the path has actually changed.
            if ($wingetPath -ne $originalPath) {
                 Write-Log "INFO: Winget path has changed to: $wingetPath"
                 # Re-check version after update as it's critical for determining feature support.
                 Write-Log "INFO: Re-checking winget version after update..."
                 $versionOutput = & "$wingetPath" --version
                 $wingetVersionString = ($versionOutput | Out-String).Trim()
                 try {
                    if ($wingetVersionString -match 'v?((?:\\d+\\.)*\\d+)') {
                        $versionString = $matches[1]
                        # The [version] constructor can fail on versions with more than 4 parts (e.g., from dev builds).
                        # Safely take up to the first 4 parts to prevent script errors.
                        $safeVersionString = ($versionString.Split('.')[0..3]) -join '.'
                        $wingetVersion = [version]$safeVersionString
                    } else {
                         $wingetVersion = [version]$wingetVersionString
                    }
                    Write-Log "INFO: Detected new winget version: $($wingetVersion.ToString())"
                 } catch {
                    Write-Log "WARN: Could not parse new winget version string: '$wingetVersionString'."
                 }
            } else {
                Write-Log "INFO: Winget path did not change. Continuing with version $($wingetVersion.ToString())."
            }
            
        } else {
            Write-Log "WARN: Winget self-update finished with a non-success exit code ($exitCode). This is often normal if it's already up-to-date. Continuing with existing version."
        }
    } catch {
         Write-Log "WARN: Winget self-update command failed to execute. This can happen on older systems where the msstore source is unavailable. Continuing with existing version."
         Write-Log "Exception: $($_.Exception.Message)"
    }

    Write-Log "[STEP 3/4] Updating winget sources..."
    & "$wingetPath" source update

    Write-Log "[STEP 4/4] Searching for and applying application updates..."

    # Get the list of upgradable packages. Accept source agreements to prevent prompts.
    Write-Log "INFO: Fetching list of available upgrades..."
    $upgradeOutput = & "$wingetPath" upgrade --accept-source-agreements
    
    if ($LASTEXITCODE -ne 0) {
        $outputStringForCheck = $upgradeOutput | Out-String
        # Some winget versions exit with a non-zero code when no updates are found.
        # Check the output to distinguish this from a genuine error.
        if ($outputStringForCheck -notmatch "No applicable update found" -and $outputStringForCheck -notmatch "No installed package found matching input criteria") {
            Write-Log "ERROR: 'winget upgrade' command failed with exit code $LASTEXITCODE. Cannot retrieve list of upgradable packages."
            Write-Log "This can happen if winget needs an update itself or if there's a problem with its sources."
            Write-Log "Winget output: $outputStringForCheck"
            throw "Winget upgrade list failed."
        }
        # If a "no updates found" error, log it and proceed. The parser will correctly find 0 packages.
        Write-Log "INFO: 'winget upgrade' returned a non-zero exit code but the output indicates no updates are available. This is normal for some versions. Continuing..."
    }
    
    # Combine multi-line output into a single string array for reliable parsing
    $lines = ($upgradeOutput | Out-String) -split "`r?`n"

    # Find the header line (it's the one before '---') and all subsequent package lines
    $headerLine = ""
    $packageLines = @()
    $separatorIndex = -1

    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -like '---*') {
            if ($i -gt 0) {
                $headerLine = $lines[$i - 1]
            }
            $separatorIndex = $i
            break
        }
    }

    if ($separatorIndex -ne -1) {
        $packageLines = $lines[($separatorIndex + 1)..$lines.Length] | Where-Object { $_.Trim().Length -gt 0 }
    }
    
    $upgradablePackageIds = @()

    if ($packageLines.Count -gt 0) {
        # Determine column positions based on the header line text to parse reliably
        # Search for " Id " with spaces to avoid matching 'Id' in a package name like 'Mozilla'.
        $idColStart = $headerLine.IndexOf(' Id ')
        $versionColStart = $headerLine.IndexOf(' Version ')

        # If we can't find the column headers, parsing will be unreliable.
        if ($idColStart -lt 0 -or $versionColStart -lt 0) {
            Write-Log "WARN: Could not determine column layout from winget output header. This can happen if there are no packages to upgrade or the output format changed. Falling back to less reliable parsing."
            $upgradablePackageIds = foreach ($line in $packageLines) {
                # Fallback: Split by 2+ spaces and assume ID is the second column. This is not always reliable.
                $columns = $line.Trim() -split '\\s{2,}'
                if ($columns.Count -ge 2) { $columns[1].Trim() }
            }
        } else {
            Write-Log "INFO: Parsing winget output using detected column positions for accuracy."
            $upgradablePackageIds = foreach ($line in $packageLines) {
                if ($line.Length -gt $versionColStart) {
                    # Extract the ID based on calculated column position
                    $line.Substring($idColStart, $versionColStart - $idColStart).Trim()
                }
            }
        }
    }
    
    if ($upgradablePackageIds.Count -eq 0) {
        Write-Log "INFO: No application updates found."
    } else {
        Write-Log "INFO: Found $($upgradablePackageIds.Count) potential updates. Applying exclusions..."
        
        # --- Define Exclusions ---
        $manualExclusions = $Exclusions | ForEach-Object { $_.ToLower() }

        # --- Basic Microsoft (or any other hard coded) Exclusions ---
        $msExclusionPatterns = @()
        if ($ExcludeMicrosoft) {
            $msExclusionPatterns = @(
                "Microsoft.Edge.*",
                "Microsoft.Edge",
                "Microsoft.Teams.*",
                "Microsoft.Office.*",
                "Microsoft.365.*",
                "Microsoft.OneDrive",
                "Microsoft.Skype",
                "Microsoft.VCRedist.*",
                "Microsoft.VisualStudio.*",
                "Microsoft.WindowsTerminal",
                "Microsoft.PowerShell.*",
                "Microsoft.PowerToys",
                "Microsoft.DotNet.*",
                "Microsoft.NET.*",
                "Microsoft.WindowsSDK",
                "Microsoft.WindowsAppRuntime.*"
            )
        }
        # --- End Exclusions ---
        
        $packagesToUpgrade = @()
        foreach ($packageId in $upgradablePackageIds) {
            $isExcluded = $false
            
            # Check against manual exact-match exclusions (case-insensitive)
            if ($manualExclusions -contains $packageId.ToLower()) {
                $isExcluded = $true
                Write-Log "INFO: Skipping '$packageId' due to manual exclusion."
            }
            
            # Check against MS wildcard patterns
            if (!$isExcluded -and $msExclusionPatterns.Count -gt 0) {
                foreach ($pattern in $msExclusionPatterns) {
                    if ($packageId -like $pattern) {
                        $isExcluded = $true
                        Write-Log "INFO: Skipping '$packageId' due to Microsoft exclusion pattern '$pattern'."
                        break # Exit inner loop once a match is found
                    }
                }
            }
            
            if (!$isExcluded) {
                $packagesToUpgrade += $packageId
            }
        }
        
        if ($packagesToUpgrade.Count -gt 0) {
            Write-Log "INFO: Attempting to upgrade $($packagesToUpgrade.Count) filtered packages..."
            $totalPackages = $packagesToUpgrade.Count
            $currentPackage = 0
            $successfullyUpgraded = @()
            $failedUpgrades = @()

            foreach ($packageId in $packagesToUpgrade) {
                $currentPackage++
                Write-Log "--- [$currentPackage/$totalPackages] Upgrading package: $packageId ---"
                
                $arguments = @(
                    "upgrade",
                    "--id", $packageId,
                    "--silent",
                    "--accept-source-agreements",
                    "--accept-package-agreements",
                    "--source", "winget"
                )
                
                # Add optional arguments
                if ($IncludeUnknown) {
                    $arguments += "--include-unknown"
                }
                if ($ForceUpgrade) {
                    $arguments += "--force"
                }
                
                Write-Log "Executing Command: & '$($wingetPath.Replace("'", "''"))' $($arguments -join ' ')"
                & "$wingetPath" $arguments
                
                $exitCode = $LASTEXITCODE
                if ($exitCode -eq 0 -or $exitCode -eq 1641 -or $exitCode -eq 3010) {
                    Write-Log "SUCCESS: Package '$packageId' upgrade finished with code: $exitCode."
                    $successfullyUpgraded += @{ ID = $packageId; ExitCode = $exitCode }
                } elseif ($exitCode -eq -1978335188) { # WINGET_EXIT_CODE_INSTALLER_HASH_MISMATCH
                     Write-Log "ERROR: Package '$packageId' failed with an INSTALLER HASH MISMATCH. This is an issue with the package manifest and not the script."
                     $failedUpgrades += @{ ID = $packageId; ExitCode = $exitCode; Reason = 'Installer Hash Mismatch' }
                } else {
                    Write-Log "ERROR: Package '$packageId' upgrade failed with exit code: $exitCode. See winget return code documentation for details."
                    $failedUpgrades += @{ ID = $packageId; ExitCode = $exitCode; Reason = 'See winget documentation' }
                }
                Write-Log "----------------------------------------------------"
            }
            Write-Log "INFO: Finished processing all packages."
            
            # --- Generate Final Report ---
            Write-Log ""
            Write-Log "=================================================="
            Write-Log "               Upgrade Summary Report"
            Write-Log "=================================================="
            Write-Log ""

            Write-Log "PACKAGES WITH UPGRADES:"
            if ($upgradablePackageIds.Count -gt 0) {
                foreach ($packageId in $upgradablePackageIds) {
                    Write-Log "  - $packageId"
                }
            }
            Write-Log ""

            if ($successfullyUpgraded.Count -gt 0) {
                Write-Log "SUCCESSFUL UPGRADES ($($successfullyUpgraded.Count) total):"
                foreach ($package in $successfullyUpgraded) {
                    Write-Log "  - $($package.ID) (Exit Code: $($package.ExitCode))"
                }
            } else {
                Write-Log "SUCCESSFUL UPGRADES: None"
            }
            
            Write-Log ""

            if ($failedUpgrades.Count -gt 0) {
                Write-Log "FAILED UPGRADES ($($failedUpgrades.Count) total):"
                foreach ($package in $failedUpgrades) {
                    Write-Log "  - $($package.ID) (Exit Code: $($package.ExitCode) - Reason: $($package.Reason))"
                }
            } else {
                Write-Log "FAILED UPGRADES: None"
            }
            
            Write-Log ""
            Write-Log "=================================================="
            # --- End of Report ---

        } else {
            Write-Log "INFO: All found updates were excluded. No packages to upgrade."
        }
    }

} catch {
    Write-Log "ERROR: An unexpected PowerShell error occurred during the winget execution."
    Write-Log "Exception Message: $($_.Exception.Message)"
    Write-Log "Script StackTrace: $($_.ScriptStackTrace)"
}

Write-Log "=================================================="
Write-Log "Script finished at $(Get-Date)"
Write-Log "=================================================="

# Stop logging
Stop-Transcript
