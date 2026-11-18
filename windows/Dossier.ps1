# Dossier.ps1 - dot-source from $PROFILE to get cc, cc-<key>, and a routed `claude`:
#   . C:\path\to\dossier\windows\Dossier.ps1
# For Git Bash, source ../dossier.bash instead.
#
# `claude` is routed through the launcher too, so typing it instead of cc can't start a session
# in the wrong home. The launcher still runs the real claude.exe from PATH. Set
# DOSSIER_NO_CLAUDE_SHIM=1 before loading to keep plain claude.

if ($PSVersionTable.PSVersion.Major -lt 7) { Write-Warning 'dossier needs PowerShell 7; cc was not defined.'; return }
$global:DossierDir = $PSScriptRoot

function global:cc { & (Join-Path $global:DossierDir 'Invoke-Dossier.ps1') @args }
if (-not $env:DOSSIER_NO_CLAUDE_SHIM) {
    function global:claude { & (Join-Path $global:DossierDir 'Invoke-Dossier.ps1') @args }
}

. (Join-Path $PSScriptRoot 'Dossier.Common.ps1')
try {
    foreach ($e in (Read-DsrRegistry).Entries) {
        Set-Item -Path "function:global:cc-$($e.Key)" -Value ([ScriptBlock]::Create("& (Join-Path `$global:DossierDir 'Invoke-Dossier.ps1') --account '$($e.Key)' @args"))
    }
} catch { }
