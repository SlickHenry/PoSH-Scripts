#Requires -Version 3.0
<#
.SYNOPSIS
    Logs the device serial number and logged-in user to the Application event log
    using structured EventData fields.

.DESCRIPTION
    Intended to run silently at user logon via a GPO Preferences Scheduled
    Task. Writes an event with insertion strings, placing the device serial number 
    in the TargetInfo field position consistently. The Scheduled Task approach 
    ensures no console window is visible to the user during execution.

    EventData field positions:
      [0] SubjectUserSid
      [1] SubjectUserName
      [2] SubjectDomainName
      [3] SubjectLogonId       (hex logon session ID)
      [4] LogonGuid            (not applicable - empty)
      [5] TargetUserName       (same as SubjectUserName)
      [6] TargetDomainName     (same as SubjectDomainName)
      [7] TargetInfo           *** DEVICE SERIAL NUMBER ***
      [8] ProcessId            (current PID)
      [9] ProcessName          (PowerShell path)
      [10] IpAddress           (local IP)
      [11] IpPort              (not applicable - "0")

.NOTES
    Prerequisites:
      - The "LogonAudit" event source must be pre-registered before this
        script runs. Use Register-LogonAuditSource.ps1 as a GPO Computer
        Startup script to handle this (it runs as SYSTEM with admin rights).

    Deployment:
      1. Deploy Register-LogonAuditSource.ps1 as a Computer Startup script:
           Computer Configuration
             -> Policies
               -> Windows Settings
                 -> Scripts (Startup/Shutdown)
                   -> Startup -> PowerShell Scripts

      2. Place this script on the NETLOGON share or a UNC path accessible
         by authenticated users (e.g. \\domain\NETLOGON\LogonAudit.ps1).

      3. Create a Scheduled Task via GPO Preferences:
           User Configuration
             -> Preferences
               -> Control Panel Settings
                 -> Scheduled Tasks
                   -> New -> Scheduled Task (At least Windows 7)

         General tab:
           - Action          : Create
           - Run as           : %LogonDomain%\%LogonUser%
           - Run whether user is logged on or not : Checked
           - Hidden           : Checked

         Triggers tab:
           - Begin the task   : At log on
           - Specific user    : (leave blank for any user)

         Actions tab:
           - Action           : Start a program
           - Program/script   : powershell.exe
           - Arguments        : -ExecutionPolicy Bypass -WindowStyle Hidden
                                -NonInteractive -File "\\path\to\LogonAudit.ps1"

         Settings tab:
           - Allow task to be run on demand          : Yes
           - Stop the task if it runs longer than     : 5 minutes
           - If the running task does not end...      : Stop the task

    No local-admin rights are required for this script.
    No console window is displayed to the end user.
#>

# ---------- Configuration ----------
$EventSource = "LogonAudit"
$EventLog    = "Application"
$EventId     = 1000
# ------------------------------------

# ---------- Helper: get serial with fallback ----------
function Get-DeviceSerial {
    $InvalidValues = @('', 'Default string', 'To be filled by O.E.M.', 'None',
                       'Not Specified', 'System Serial Number', 'O.E.M.')

    $Sources = @(
        @{ Class = 'Win32_BIOS';                  Property = 'SerialNumber' },
        @{ Class = 'Win32_SystemEnclosure';        Property = 'SerialNumber' },
        @{ Class = 'Win32_BaseBoard';              Property = 'SerialNumber' },
        @{ Class = 'Win32_ComputerSystemProduct';  Property = 'IdentifyingNumber' }
    )

    foreach ($Source in $Sources) {
        try {
            $Value = (Get-CimInstance -ClassName $Source.Class -ErrorAction Stop).$($Source.Property)
            if ($Value -is [array]) { $Value = $Value[0] }
            $Value = "$Value".Trim()
            if ($Value -and $Value -notin $InvalidValues) { return $Value }
        }
        catch { continue }
    }
    return "UNKNOWN"
}
# -------------------------------------------------------

# ---------- Collect identity info ----------
$Identity       = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$SubjectUserSid = $Identity.User.Value

# Split DOMAIN\Username
$Parts              = $Identity.Name -split '\\', 2
$SubjectDomainName  = $Parts[0]
$SubjectUserName    = if ($Parts.Count -gt 1) { $Parts[1] } else { $Parts[0] }

# Logon session ID (hex, matches 4648 format)
$LogonIdHex = '0x{0:X}' -f [int64]$Identity.Token.ToInt64()

# Device serial -> TargetInfo
$TargetInfo = Get-DeviceSerial

# Process info
$ProcessId   = $PID.ToString()
$ProcessName = (Get-Process -Id $PID).Path

# Local IP address (first non-loopback IPv4)
$IpAddress = (
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' } |
    Select-Object -First 1
).IPAddress
if (-not $IpAddress) { $IpAddress = '127.0.0.1' }

# ---------- Build insertion strings (4648 field order) ----------
$InsertionStrings = @(
    $SubjectUserSid,        # [0]  SubjectUserSid
    $SubjectUserName,       # [1]  SubjectUserName
    $SubjectDomainName,     # [2]  SubjectDomainName
    $LogonIdHex,            # [3]  SubjectLogonId
    '{00000000-0000-0000-0000-000000000000}', # [4] LogonGuid (N/A)
    $SubjectUserName,       # [5]  TargetUserName
    $SubjectDomainName,     # [6]  TargetDomainName
    $TargetInfo,            # [7]  TargetInfo  <- SERIAL NUMBER
    $ProcessId,             # [8]  ProcessId
    $ProcessName,           # [9]  ProcessName
    $IpAddress,             # [10] IpAddress
    '0'                     # [11] IpPort (N/A)
)

# ---------- Verify source is registered ----------
if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
    Write-Error "Event source '$EventSource' is not registered. Run Register-LogonAuditSource.ps1 as a Startup script first."
    exit 1
}

# ---------- Write structured event ----------
try {
    $EventInstance = New-Object System.Diagnostics.EventInstance(
        $EventId,                                          # Event ID
        0,                                                 # Category
        [System.Diagnostics.EventLogEntryType]::Information
    )

    $Log        = New-Object System.Diagnostics.EventLog($EventLog)
    $Log.Source = $EventSource
    $Log.WriteEvent($EventInstance, $InsertionStrings)

    Write-Output "Event $EventId written to $EventLog log."
    Write-Output "  Serial (TargetInfo) : $TargetInfo"
    Write-Output "  User               : $SubjectDomainName\$SubjectUserName"
}
catch {
    Write-Error "Failed to write event: $_"
    exit 1
}
