# dossier-guard.ps1 - SessionStart hook: is this session running in the home that owns its folder?
# Sync-Dossier.ps1 wires it into every home's settings.json. Always exits 0; it informs, never blocks.
#
#   Folder owned by an entry, session in another home      -> CRITICAL (wrong config, memory and
#                                                             MCP servers; for an enterprise client,
#                                                             also the wrong data terms)
#   Right home, logged in to the wrong account             -> CRITICAL
#   Folder under the workspace but in no registered root   -> NOTE
#   Can't read what it needs                               -> INDETERMINATE note
#   Everything matches                                     -> silent
# Unlike claude-multi-account-kit's guard, the same login in a different home is not OK: two
# entries on one account (the firm and a no-seat client) still must not share config.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Dossier.Common.ps1"

function Out-Guard([string] $ForPerson, [string] $ForModel) {
    $o = [ordered]@{ systemMessage = "[dossier-guard] $ForPerson" }
    if ($ForModel) { $o.hookSpecificOutput = [ordered]@{ hookEventName = 'SessionStart'; additionalContext = $ForModel } }
    [Console]::Out.Write(($o | ConvertTo-Json -Depth 5 -Compress))
}

try {
    $in = $null
    try { $in = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { }
    $cwd = if ($in -and $in.cwd) { [string]$in.cwd } else { (Get-Location).ProviderPath }

    # Sync only wires this hook when a registry exists, so a missing one is worth saying.
    if (-not (Test-Path -LiteralPath (Get-DsrRegistryPath))) { Out-Guard "INDETERMINATE: no registry at $(Get-DsrRegistryPath), so this folder's owner can't be checked." ''; exit 0 }
    try { $reg = Read-DsrRegistry }
    catch { Out-Guard "INDETERMINATE: could not read the registry ($($_.Exception.Message))." ''; exit 0 }

    $homePath = if ($env:CLAUDE_CONFIG_DIR) { Resolve-DsrPath $env:CLAUDE_CONFIG_DIR } else { Get-DsrDefaultHome }
    $session = Find-DsrEntryByHome $reg $homePath
    $sessionName = if ($session) { "'$($session.Key)' ($homePath)" } else { "unregistered home $homePath" }
    $owner = Find-DsrOwner $reg $cwd

    if ($owner.State -eq 'owned') {
        $o = $owner.Entry
        if (-not (Test-DsrSamePath $o.Home $homePath)) {
            $why = "Its CLAUDE.md, memory, skills and MCP servers are not loaded, and this session's are."
            if ($o.Seat -eq 'enterprise') { $why += " It is an enterprise-seat client, so its files must not be read under another account." }
            $msg = "CRITICAL: this folder belongs to '$($o.Key)', but the session runs in $sessionName. $why Exit and relaunch here with cc."
            Out-Guard $msg "Dossier guard: $msg Tell the user before doing anything else, and do not read files in this folder until they relaunch."
            exit 0
        }
        $id = Read-DsrIdentity $homePath
        if ($id.Status -ne 'ok') {
            Out-Guard "INDETERMINATE: could not read the login for '$($o.Key)' from $($id.File) ($($id.Status)). Run /login as $(Get-DsrExpectText $o)." ''
            exit 0
        }
        if ((Test-DsrIdentityMatches $o $id) -eq $false) {
            $msg = "CRITICAL: '$($o.Key)' should be logged in as $(Get-DsrExpectText $o), but this home is logged in as $($id.Email). Run /logout, then /login."
            Out-Guard $msg "Dossier guard: $msg Tell the user before doing anything else."
            exit 0
        }
        exit 0
    }
    if ($owner.State -eq 'unregistered') {
        Out-Guard "NOTE: $cwd is under $($reg.WorkspaceRoot) but in no registered root, so it runs as $sessionName by default. Move it under a client root or the sandbox." ''
    }
} catch {
    Out-Guard "INDETERMINATE: the guard failed ($($_.Exception.Message))." ''
}
exit 0
