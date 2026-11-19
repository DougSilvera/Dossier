# Import-Dossier.ps1 - bring a registered client or template's repos onto this machine.
# Shows the plan; -Apply does it.
#
#   pwsh -File Import-Dossier.ps1 -Key base-template           # dry run
#   pwsh -File Import-Dossier.ps1 -Key base-template -Apply
#
# The entry must already be in the registry, with its repos listed:
#   "repos": [{ "remote": "git@host:org/repo.git", "dir": "optional folder name" }]
# Runs Sync-Dossier (roots, homes, rules), clones each repo that isn't in <root>\<dir> yet, then
# runs Test-Dossier. Never touches a folder that already exists. Refuses an enterprise-seat
# client from inside a Claude session: run it from your own terminal.

param([Parameter(Mandatory)] [string] $Key, [switch] $Apply)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Dossier.Common.ps1"
if (-not (Test-DsrPowerShell7)) { Write-DsrErr 'Import-Dossier needs PowerShell 7 (pwsh).'; exit 1 }

try { $reg = Read-DsrRegistry } catch { Write-DsrErr $_.Exception.Message; exit 1 }

$entry = Find-DsrEntry $reg $Key
$template = Find-DsrTemplate $reg $Key
if ($entry -and $entry.Kind -eq 'client') { $root = $entry.Roots[0]; $repos = $entry.Repos; $what = "client '$($entry.Key)' ($($entry.Seat) seat)" }
elseif ($template) { $root = $template.Root; $repos = $template.Repos; $what = "template '$($template.Key)' (firm home)" }
else {
    Write-DsrErr "No client or template '$Key' in $($reg.Path). Add it first, for example:"
    Write-DsrErr '  "templates": [{ "key": "<key>", "name": "<name>", "root": "~/workspace/templates/<key>", "enterpriseRead": false, "repos": [{ "remote": "<ssh url>" }] }]'
    exit 1
}
if ($entry -and $entry.Seat -eq 'enterprise' -and $env:CLAUDECODE) {
    Write-DsrErr "Refused: '$($entry.Key)' is an enterprise seat, and this is a Claude session. Run Import-Dossier from your own terminal."
    exit 1
}
if (-not @($repos).Count) { Write-DsrErr "$what has no repos in the registry. Add \"repos\": [{ \"remote\": \"<url>\" }] to its entry."; exit 1 }

Write-Host "Import $what into $root$(if (-not $Apply) { '  (dry run; -Apply to make changes)' })"
Write-Host '-- Sync-Dossier'
& "$PSScriptRoot\Sync-Dossier.ps1" -Apply:$Apply
if ($LASTEXITCODE) { Write-DsrErr 'Sync-Dossier failed; nothing cloned.'; exit 1 }

Write-Host '-- repos'
$failed = 0
foreach ($r in $repos) {
    $dest = Join-Path $root $r.Dir
    if (Test-Path -LiteralPath (Join-Path $dest '.git')) { Write-Host "  ok    $dest already cloned"; continue }
    if (Test-Path -LiteralPath $dest) { Write-Host "  skip  $dest exists but isn't a git repo; move it aside and rerun"; $failed++; continue }
    if (-not $Apply) { Write-Host "  plan  clone $($r.Remote) -> $dest"; continue }
    & git clone -- $r.Remote $dest
    if ($LASTEXITCODE) { Write-Host "  FAIL  clone $($r.Remote)"; $failed++ } else { Write-Host "  done  clone $($r.Remote) -> $dest" }
}

if ($Apply) {
    Write-Host '-- Test-Dossier'
    & "$PSScriptRoot\Test-Dossier.ps1"
}
if ($failed) { exit 1 }
exit 0
