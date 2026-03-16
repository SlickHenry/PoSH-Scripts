# PoSH-Scripts

PowerShell scripts collection.

---

## Table of Contents

- [Scripts](#scripts)
  - [LogonAudit](#logonaudit)

---

## Scripts

### LogonAudit

Writes the device serial number and logged-in user to the Application event log at each logon. The event uses structured insertion strings. The serial number is placed in the **TargetInfo** field (index 7).

| File | Context | Purpose |
|---|---|---|
| `Register-LogonAuditSource.ps1` | SYSTEM — GPO Computer Startup | One-time registration of the `LogonAudit` event source |
| `LogonAudit.ps1` | Standard user — GPO Preferences Scheduled Task | Writes the audit event silently at each logon |

**Deployment:** 
Deploy the registration script as a Computer Startup script, then deploy `LogonAudit.ps1` via a GPO Preferences Scheduled Task triggered at logon. 
Run the task as `%LogonDomain%\%LogonUser%` with the **Hidden** flag checked and the action set to:

```
powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File "\\domain\NETLOGON\LogonAudit.ps1"
```

**Verify:**

```powershell
Get-WinEvent -LogName Application -MaxEvents 10 | Where-Object { $_.Id -eq 1000 } | Select-Object -First 1 | Format-List TimeCreated, Message
```

Full configuration details (GPO paths, Scheduled Task tab settings, field mapping reference, and troubleshooting) are documented in each script's comment-based help — run `Get-Help .\ScriptName.ps1 -Full` to view.

---

## Testing

All scripts include comment-based help with local testing steps. General pattern:

```powershell
# View built-in documentation
Get-Help .\ScriptName.ps1 -Full

# Run
.\ScriptName.ps1
```
---
