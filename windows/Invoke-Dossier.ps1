# Invoke-Dossier.ps1 - start Claude Code in the home that owns the current folder.
#
#   cc                         # the home that owns this folder (the firm's outside every client root)
#   cc -a acme                 # or --account: that entry's home, from any folder it may run in
#   cc -a widgetco --at-root -p "status of ABC-123?"   # cd to the entry's root first
#   cc -a base-template --at-root   # a template key: the firm home, in that template's root
#   cc --dossier-override      # start an enterprise home despite a login or provider mismatch
# Every other argument goes to claude unchanged. Messages go to stderr.
# Registry: ~/.dossier.json, or $env:DOSSIER_CONFIG. $env:CLAUDE_BIN overrides claude.
#
# Refuses, for an enterprise-seat client (its data must stay under its own account):
#   - its folder, or an --add-dir into it, opened in any other home
#   - a launch from inside another home's Claude session, either direction (the output comes
#     back to the caller). This stops accidents; a session that strips CLAUDECODE gets past it.
#   - its home logged in to the wrong account, or an API key, base URL, Bedrock or Vertex set in
#     the shell or the home's settings, unless --dossier-override
# Clears only the variables a Claude session hands its children (Dossier.Common.ps1), so a
# launch from inside a session starts clean; restores them afterwards. Never copies between homes.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Dossier.Common.ps1"
if (-not (Test-DsrPowerShell7)) { Write-DsrErr '[cc] needs PowerShell 7 (pwsh).'; exit 1 }

$explicit = $null; $atRoot = $false; $override = $false; $addDirs = @()
$pass = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $args.Count; $i++) {
    # PowerShell hands `a,b` over as an array; claude expects the comma list back.
    $t = if ($args[$i] -is [array]) { $args[$i] -join ',' } else { [string]$args[$i] }
    # PowerShell reads `--opt=C:\x` as `-name:value` and splits it at the drive colon.
    if ($t -match '^-.*=[A-Za-z]$' -and $i + 1 -lt $args.Count -and ([string]$args[$i + 1]) -match '^[\\/]') { $t += ':' + [string]$args[++$i] }
    if ($t -ceq '-a' -or $t -ceq '--account') {
        if ($i + 1 -ge $args.Count) { Write-DsrErr "[cc] $t needs a key."; exit 1 }
        $explicit = [string]$args[++$i]; continue
    }
    if ($t.StartsWith('--account=')) { $explicit = $t.Substring(10); continue }
    if ($t -ceq '--at-root') { $atRoot = $true; continue }
    if ($t -ceq '--dossier-override') { $override = $true; continue }
    if ($t.StartsWith('--add-dir=')) { $addDirs += $t.Substring(10) }
    elseif ($t -ceq '--add-dir') {
        $pass.Add($t)
        while ($i + 1 -lt $args.Count -and -not ([string]$args[$i + 1]).StartsWith('-')) { $i++; $addDirs += [string]$args[$i]; $pass.Add([string]$args[$i]) }
        continue
    }
    $pass.Add($t)
}

try { $reg = Read-DsrRegistry } catch { Write-DsrErr "[cc] $($_.Exception.Message)"; exit 1 }

$entry = $null; $root = $null
if ($explicit) {
    $entry = Find-DsrEntry $reg $explicit
    if ($entry) { $root = @($entry.Roots)[0] }
    elseif ($t = Find-DsrTemplate $reg $explicit) { $entry = Find-DsrFirm $reg; $root = $t.Root }
    else { Write-DsrErr "[cc] no entry '$explicit'. Known: $((@($reg.Entries | ForEach-Object Key) + @($reg.Templates | ForEach-Object Key)) -join ', ')"; exit 1 }
}

$pushed = $false
if ($atRoot) {
    if (-not $entry) { Write-DsrErr '[cc] --at-root needs -a <key>.'; exit 1 }
    if (-not (Test-Path -LiteralPath $root)) { Write-DsrErr "[cc] $root doesn't exist. Run Sync-Dossier.ps1 -Apply."; exit 1 }
    Push-Location -LiteralPath $root; $pushed = $true
}

try {
    $cwd = (Get-Location).ProviderPath
    $owner = Find-DsrOwner $reg $cwd

    if (-not $entry) {
        if ($owner.State -eq 'owned') { $entry = $owner.Entry; $via = 'this folder is in its root' }
        else {
            $entry = Find-DsrFirm $reg
            $via = 'outside every client root'
            if ($owner.State -eq 'unregistered') { Write-DsrErr "[cc] note: $cwd is under $($reg.WorkspaceRoot) but in no registered root. Using the firm home." }
        }
    } else { $via = 'chosen with --account' }

    foreach ($o in @(@{ Owner = $owner; What = 'this folder' }) + @($addDirs | ForEach-Object { @{ Owner = (Find-DsrOwner $reg $_); What = "--add-dir $_" } })) {
        $oe = $o.Owner.Entry
        if ($o.Owner.State -ne 'owned' -or $oe.Key -eq $entry.Key) { continue }
        if ($oe.Seat -eq 'enterprise') {
            Write-DsrErr "[cc] refused: $($o.What) belongs to '$($oe.Key)' (enterprise seat). Only its own home may open it."
            exit 1
        }
        Write-DsrErr "[cc] note: $($o.What) belongs to '$($oe.Key)'; starting '$($entry.Key)' anyway, as asked. Its config, memory and MCP servers won't load."
    }

    # A session that starts another home gets that home's output back, so an enterprise client's
    # data would cross accounts in either direction.
    if ($env:CLAUDECODE) {
        $callerHome = if ($env:CLAUDE_CONFIG_DIR) { Resolve-DsrRealPath $env:CLAUDE_CONFIG_DIR } else { Get-DsrDefaultHome }
        $caller = Find-DsrEntryByHome $reg $callerHome
        if (-not (Test-DsrSamePath $callerHome $entry.Home) -and ($entry.Seat -eq 'enterprise' -or ($caller -and $caller.Seat -eq 'enterprise'))) {
            $who = if ($caller) { "'$($caller.Key)'" } else { $callerHome }
            Write-DsrErr "[cc] refused: a Claude session in $who can't start '$($entry.Key)'; an enterprise client's data would cross accounts. Start it from your own terminal."
            exit 1
        }
    }

    $bin = $env:CLAUDE_BIN
    if (-not $bin) { $bin = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source }
    if (-not $bin) { Write-DsrErr '[cc] claude not found on PATH (or set CLAUDE_BIN).'; exit 1 }

    if (-not (Test-Path -LiteralPath $entry.Home)) { Write-DsrErr "[cc] $($entry.Home) doesn't exist. Run Sync-Dossier.ps1 -Apply."; exit 1 }

    $problems = New-Object System.Collections.Generic.List[string]
    $id = Read-DsrIdentity $entry.Home
    if ($id.Status -eq 'ok') {
        Write-DsrErr "[cc] $($entry.Key): $($id.Email) - $via"
        if ((Test-DsrIdentityMatches $entry $id) -eq $false) { $problems.Add("$($entry.Home) is logged in as $($id.Email), expected $(Get-DsrExpectText $entry). Run /logout, then /login.") }
    } else {
        Write-DsrErr "[cc] $($entry.Key): not logged in yet - $via. Run /login, as $(Get-DsrExpectText $entry)."
    }

    $homeEnv = @{}
    $settingsFile = Join-Path $entry.Home 'settings.json'
    if (Test-Path -LiteralPath $settingsFile) {
        try { $se = ([IO.File]::ReadAllText($settingsFile) | ConvertFrom-Json -AsHashtable).env; if ($se) { $homeEnv = $se } } catch { }
    }
    foreach ($v in @('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX')) {
        $where = @()
        if ([Environment]::GetEnvironmentVariable($v)) { $where += 'this shell' }
        if ($homeEnv.Contains($v) -and $homeEnv[$v]) { $where += "$settingsFile env" }
        if ($where) { $problems.Add("$v is set in $($where -join ' and '); requests may not go to '$($entry.Key)'s subscription login.") }
    }
    foreach ($p in $problems) {
        if ($entry.Seat -eq 'enterprise' -and -not $override) { Write-DsrErr "[cc] refused: $p '$($entry.Key)' is an enterprise seat. Fix it, or pass --dossier-override."; exit 1 }
        Write-DsrErr "[cc] WARNING: $p"
    }

    $saved = @{}
    try {
        foreach ($v in @(Get-ChildItem Env:)) {
            if ($v.Name -match $script:DsrSessionVars) { $saved[$v.Name] = $v.Value; Remove-Item -LiteralPath "Env:\$($v.Name)" }
        }
        if (-not (Test-DsrDefaultHome $entry.Home)) { $env:CLAUDE_CONFIG_DIR = $entry.Home }
        $passArgs = $pass.ToArray()
        & $bin @passArgs
        $code = $LASTEXITCODE
    } finally {
        if (Test-Path Env:\CLAUDE_CONFIG_DIR) { Remove-Item Env:\CLAUDE_CONFIG_DIR }
        foreach ($k in $saved.Keys) { Set-Item -LiteralPath "Env:\$k" -Value $saved[$k] }
    }
    exit $code
} finally {
    if ($pushed) { Pop-Location }
}
