#Requires -Version 3.0
<#
.SYNOPSIS
    Registers the "LogonAudit" event source in the Application event log.

.DESCRIPTION
    This script is a companion to LogonAudit.ps1 and must run before it.
    It registers the custom event source "LogonAudit" in the Application log
    so that the logon script can write structured events without requiring
    local-admin privileges.

    Because GPO User Logon scripts execute in the logged-in user's context
    (which typically lacks admin rights), the event source must be
    pre-registered by a process running as SYSTEM. A GPO Computer Startup
    script is ideal for this — it runs as SYSTEM before any user logs in.

    The script is idempotent: if the source already exists it exits
    immediately with no changes.

.NOTES
    Deployment:
      1. Place this script on the NETLOGON share or a network path
         accessible by machine accounts.
      2. Assign it via Group Policy:
           Computer Configuration
             -> Policies
               -> Windows Settings
                 -> Scripts (Startup/Shutdown)
                   -> Startup -> PowerShell Scripts
      3. Deploy LogonAudit.ps1 as a GPO Preferences Scheduled Task
         triggered at user logon (see LogonAudit.ps1 notes for full
         task configuration). This ensures silent, windowless execution.

    Requirements:
      - Runs as SYSTEM (handled automatically by GPO Startup).
      - One-time registration; safe to leave the GPO applied permanently
        as the script skips registration if the source already exists.

    Logging:
      - Success and skip events are written to the Application log under
        the source "Application" so you can confirm deployment.
#>

# ---------- Configuration ----------
$EventSource = "LogonAudit"
$EventLog    = "Application"
# ------------------------------------

if ([System.Diagnostics.EventLog]::SourceExists($EventSource)) {
    Write-Output "Event source '$EventSource' already registered. No action needed."
    exit 0
}

try {
    New-EventLog -LogName $EventLog -Source $EventSource -ErrorAction Stop
    Write-Output "Event source '$EventSource' registered successfully in the '$EventLog' log."
}
catch {
    Write-Error "Failed to register event source '$EventSource': $_"
    exit 1
}
