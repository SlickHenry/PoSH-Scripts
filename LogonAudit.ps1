#Requires -Version 3.0
<#
.SYNOPSIS
    Logs the device serial number and logged-in user to the Application event log.

.DESCRIPTION
    Intended to run as a logon script (via GPO, Scheduled Task, etc.).
    Writes an event with insertion strings in the same positional layout as
    Security Event 4648, placing the device serial number in the TargetInfo
    field position. As serial numbers are not always available from bios in
    a consistent manner, try collecting the number from multiple locations.

    EventData field positions (mirrors 4648):
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
    - First run requires local-admin rights to register the event source.
    - Deploy via GPO logon script, Scheduled Task (trigger: logon), or Intune.
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

# ---------- Build insertion strings ----------
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

# ---------- Register source if needed ----------
if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
    try {
        New-EventLog -LogName $EventLog -Source $EventSource -ErrorAction Stop
    }
    catch {
        Write-Warning "Could not register source '$EventSource'. Using 'Application'. Error: $_"
        $EventSource = "Application"
    }
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
