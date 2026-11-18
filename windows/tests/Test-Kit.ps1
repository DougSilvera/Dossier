# Test-Kit.ps1 - runs every dossier tool against a throwaway USERPROFILE. Never touches yours.
#   pwsh -NoProfile -File windows\tests\Test-Kit.ps1

$ErrorActionPreference = 'Stop'
$win = Split-Path $PSScriptRoot -Parent
$script:pass = 0; $script:fail = 0
function Check([string] $Name, [bool] $Ok, [string] $Detail = '') {
    if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name $Detail" -ForegroundColor Red }
}

$saveVars = 'USERPROFILE', 'CLAUDECODE', 'CLAUDE_CONFIG_DIR', 'CLAUDE_CODE_CHILD_SESSION', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'CLAUDE_CODE_GIT_BASH_PATH', 'DOSSIER_CONFIG', 'CLAUDE_BIN', 'PATH'
$saved = @{}; foreach ($v in $saveVars) { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }
foreach ($v in 'CLAUDECODE', 'CLAUDE_CONFIG_DIR', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL') { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("dossier-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
$tmp = (Get-Item -LiteralPath $tmp).FullName
$env:USERPROFILE = $tmp
$env:DOSSIER_CONFIG = Join-Path $tmp '.dossier.json'
$ws = Join-Path $tmp 'workspace'
$substDrive = $null

function Write-Registry($Clients, [string] $Personal = '~/.dossier/personal.md', [string[]] $Shared = @()) {
    $r = [ordered]@{
        workspaceRoot = '~/workspace'; personalRules = $Personal; sharedSkills = $Shared
        firm = [ordered]@{ hubRoot = '~/workspace/hub'; sandboxRoot = '~/workspace/sandbox'; expectEmail = 'me@firm.test' }
        clients = $Clients
    }
    [IO.File]::WriteAllText($env:DOSSIER_CONFIG, ($r | ConvertTo-Json -Depth 8))
}
$acme = [ordered]@{ key = 'acme'; name = 'Acme'; root = '~/workspace/clients/acme'; seat = 'enterprise'; expectEmail = 'me@acme.test'; formerRoots = @('~/workspace/acme-old') }
$widget = [ordered]@{ key = 'widgetco'; name = 'WidgetCo'; root = '~/workspace/clients/widgetco'; seat = 'none'; expectEmail = 'me@firm.test' }
function Client([hashtable] $Extra) { $c = [ordered]@{ key = 'x'; root = '~/workspace/clients/x'; seat = 'none' }; foreach ($k in $Extra.Keys) { $c[$k] = $Extra[$k] }; return $c }

function Run([string] $Script, [string[]] $ScriptArgs = @(), [string] $Cwd = $tmp, [string] $Stdin = '') {
    $psi = [Diagnostics.ProcessStartInfo]::new('pwsh')
    foreach ($a in @('-NoProfile', '-File', (Join-Path $win $Script)) + $ScriptArgs) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $Cwd
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    $psi.UseShellExecute = $false
    $p = [Diagnostics.Process]::Start($psi)
    if ($Stdin) { $p.StandardInput.Write($Stdin) }
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    return [pscustomobject]@{ Code = $p.ExitCode; Out = $out.Result; Err = $err.Result }
}
function RunExe([string] $Exe, [string[]] $ExeArgs, [string] $Cwd) {
    $psi = [Diagnostics.ProcessStartInfo]::new($Exe)
    foreach ($a in $ExeArgs) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $Cwd
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    return [pscustomobject]@{ Code = $p.ExitCode; Out = $out.Result; Err = $err.Result }
}
function Read-Json([string] $Path) { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable) }
function Set-Login([string] $StateFile, [string] $Email) {
    [IO.File]::WriteAllText($StateFile, (@{ oauthAccount = @{ emailAddress = $Email; organizationUuid = 'org'; organizationName = 'Org' } } | ConvertTo-Json))
}
function Rule([string] $Path, [switch] $File) {
    $p = '//' + $Path.Substring(0, 1).ToLower() + $Path.Substring(2).Replace('\', '/')
    if ($File) { return "Read($p)" } return "Read($p/**)"
}

try {
    . (Join-Path $win 'Dossier.Common.ps1')

    # --- registry validation
    $bad = @(
        @{ n = 'nested roots'; c = @($acme, (Client @{ root = '~/workspace/clients/acme/inner' })) },
        @{ n = 'enterprise without expectation'; c = @(Client @{ seat = 'enterprise' }) },
        @{ n = 'client on ~/.claude'; c = @(Client @{ home = '~/.claude' }) },
        @{ n = 'client home inside ~/.claude'; c = @(Client @{ home = '~/.claude/x' }) },
        @{ n = 'client home inside a root'; c = @(Client @{ home = '~/workspace/clients/x/home' }) },
        @{ n = 'client home inside another home'; c = @((Client @{ home = '~/h' }), (Client @{ key = 'y'; root = '~/workspace/clients/y'; home = '~/h/y' })) },
        @{ n = 'relative root'; c = @(Client @{ root = 'workspace/clients/x' }) },
        @{ n = 'bad seat'; c = @(Client @{ seat = 'maybe' }) },
        @{ n = 'reserved key'; c = @(Client @{ key = 'firm' }) },
        @{ n = 'uppercase key'; c = @(Client @{ key = 'X' }) },
        @{ n = 'key with trailing newline'; c = @(Client @{ key = "x`n" }) },
        @{ n = 'formerRoots covering another root'; c = @($widget, (Client @{ formerRoots = @('~/workspace/clients') })) },
        @{ n = 'formerRoots covering the workspace'; c = @(Client @{ formerRoots = @('~') }) }
    )
    foreach ($b in $bad) {
        Write-Registry $b.c
        $threw = $false; try { Read-DsrRegistry | Out-Null } catch { $threw = $true }
        Check "registry rejects $($b.n)" $threw
    }
    $env:DOSSIER_CONFIG = 'relative.json'
    $threw = $false; try { Read-DsrRegistry | Out-Null } catch { $threw = $true }
    Check 'registry rejects a relative DOSSIER_CONFIG' $threw
    $env:DOSSIER_CONFIG = Join-Path $tmp '.dossier.json'

    Write-Registry @($acme, $widget)
    $reg = Read-DsrRegistry
    Check 'registry default client home' ($reg.Entries[1].Home -eq (Join-Path $tmp '.claude-homes\acme'))
    Check 'owner: client root' ((Find-DsrOwner $reg "$ws\clients\acme\repo").Entry.Key -eq 'acme')
    Check 'owner: whole segments' ((Find-DsrOwner $reg "$ws\clients\acme-old").State -eq 'unregistered')
    Check 'owner: hub is firm' ((Find-DsrOwner $reg "$ws\hub\dossier").Entry.Key -eq 'firm')
    Check 'owner: outside' ((Find-DsrOwner $reg 'C:\elsewhere').State -eq 'outside')
    Check 'owner: device path' ((Find-DsrOwner $reg "\\?\$ws\clients\acme\repo").Entry.Key -eq 'acme')
    Check 'admin share maps to its drive' ((ConvertFrom-DsrDevicePath '\\localhost\C$\x\y') -eq 'C:\x\y')
    Check 'slug' ((Get-DsrProjectSlug 'C:\Users\a b\work.x') -eq 'C--Users-a-b-work-x')
    Check 'rule path' ((ConvertTo-DsrRulePath 'C:\Users\a\w') -eq '//c/Users/a/w')

    # --- sync: dry run writes nothing
    New-Item -ItemType Directory -Path "$tmp\.dossier", "$tmp\.claude" -Force | Out-Null
    [IO.File]::WriteAllText("$tmp\.dossier\personal.md", "# Personal`n`nNo commits.`n")
    [IO.File]::WriteAllText("$tmp\.claude\settings.json", '{"theme":"dark","permissions":{"deny":["Bash(rm -rf*)"]}}')
    [IO.File]::WriteAllText("$tmp\.claude\CLAUDE.md", "# Old hand-written rules`n")
    $r = Run 'Sync-Dossier.ps1'
    Check 'sync dry run exits 0' ($r.Code -eq 0) $r.Err
    Check 'sync dry run creates nothing' (-not (Test-Path "$ws\clients") -and -not (Test-Path "$tmp\.claude-homes"))

    # --- sync: apply
    $r = Run 'Sync-Dossier.ps1' @('-Apply')
    Check 'sync apply exits 0' ($r.Code -eq 0) "$($r.Out) $($r.Err)"
    foreach ($d in @("$ws\hub", "$ws\sandbox", "$ws\clients\acme", "$ws\clients\widgetco", "$tmp\.claude-homes\acme", "$tmp\.claude-homes\widgetco")) {
        Check "sync created $d" (Test-Path $d)
    }
    $acmeRule = Rule "$ws\clients\acme"; $widgetRule = Rule "$ws\clients\widgetco"; $hubRule = Rule "$ws\hub"
    $acmeHomeRule = Rule "$tmp\.claude-homes\acme"; $widgetHomeRule = Rule "$tmp\.claude-homes\widgetco"
    $firmHomeRule = Rule "$tmp\.claude"; $firmStateRule = Rule "$tmp\.claude.json" -File
    $fz = Read-Json "$tmp\.claude\settings.json"
    Check 'firm keeps its own settings' ($fz.theme -eq 'dark' -and 'Bash(rm -rf*)' -in $fz.permissions.deny)
    Check 'firm denies enterprise client' ($acmeRule -in $fz.permissions.deny -and $acmeRule.Replace('Read(', 'Edit(') -in $fz.permissions.deny)
    Check 'firm does not deny no-seat client' ($widgetRule -notin $fz.permissions.deny)
    Check 'firm denies every client home' ($acmeHomeRule -in $fz.permissions.deny -and $widgetHomeRule -in $fz.permissions.deny)
    Check 'firm reads no-seat client' (@($fz.permissions.additionalDirectories) -contains "$ws\clients\widgetco".Replace('\', '/'))
    Check 'firm guard hook' (($fz.hooks.SessionStart | ConvertTo-Json -Depth 8) -match 'dossier-guard')
    $ac = Read-Json "$tmp\.claude-homes\acme\settings.json"
    Check 'client denies other client and hub' ($widgetRule -in $ac.permissions.deny -and $hubRule -in $ac.permissions.deny)
    Check 'client denies other homes and the firm state file' ($widgetHomeRule -in $ac.permissions.deny -and $firmHomeRule -in $ac.permissions.deny -and $firmStateRule -in $ac.permissions.deny)
    Check 'client has no additionalDirectories' (-not $ac.permissions.Contains('additionalDirectories'))
    Check 'client CLAUDE.md is personal rules' ((Get-Content -Raw "$tmp\.claude-homes\acme\CLAUDE.md") -match 'No commits')
    Check 'unmanaged ~/.claude CLAUDE.md left alone' ((Get-Content -Raw "$tmp\.claude\CLAUDE.md") -match 'Old hand-written')
    Check 'sync reports unmanaged CLAUDE.md' ($r.Out -match 'skip .*\.claude\\CLAUDE\.md')
    Check 'client root stub' ((Get-Content -Raw "$ws\clients\acme\CLAUDE.md") -match 'Acme: client standing orders')
    $hub = Get-Content -Raw "$ws\hub\CLAUDE.md"
    Check 'hub table lists both clients' ($hub -match '\| acme \| Acme \| enterprise' -and $hub -match 'widgetco .*read code')
    Check 'no CLAUDE.md at workspace root' (-not (Test-Path "$ws\CLAUDE.md"))

    $r = Run 'Sync-Dossier.ps1' @('-Apply')
    Check 'sync is idempotent' ($r.Out -match 'In sync\.') $r.Out

    # --- removing a client removes only rules sync added; every rewrite keeps its own backup
    Write-Registry @($widget)
    Run 'Sync-Dossier.ps1' @('-Apply') | Out-Null
    $fz = Read-Json "$tmp\.claude\settings.json"
    Check 'stale managed rule removed' ($acmeRule -notin @($fz.permissions.deny))
    Check 'user rule survives removal' ('Bash(rm -rf*)' -in $fz.permissions.deny)
    Check 'each settings rewrite keeps a backup' (@(Get-ChildItem "$tmp\.claude" -Filter 'settings.json.*.bak').Count -ge 2)
    Write-Registry @($acme, $widget)
    Run 'Sync-Dossier.ps1' @('-Apply') | Out-Null

    # --- sync survives empty and null settings
    foreach ($case in @('', '{"permissions":null,"hooks":null}')) {
        [IO.File]::WriteAllText("$tmp\.claude-homes\widgetco\settings.json", $case)
        $r = Run 'Sync-Dossier.ps1' @('-Apply')
        $ok = $r.Code -eq 0 -and ((Get-Content -Raw "$tmp\.claude-homes\widgetco\settings.json") -match 'dossier-guard')
        Check "sync repairs settings.json '$case'" $ok "$($r.Out) $($r.Err)"
    }

    # --- links into a client root count as that root
    $link = Join-Path $tmp 'link'
    New-Item -ItemType Junction -Path $link -Target "$ws\clients\acme" | Out-Null
    Check 'owner: junction into a root' ((Find-DsrOwner $reg "$link").Entry.Key -eq 'acme')
    $used = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object Name)
    $substDrive = @([char[]](80..90) | ForEach-Object { [string]$_ } | Where-Object { $_ -notin $used })[0]
    if ($substDrive) {
        subst "${substDrive}:" "$ws\clients" | Out-Null
        Check 'owner: subst drive into a root' ((Find-DsrOwner $reg "${substDrive}:\acme").Entry.Key -eq 'acme')
    }

    # --- launcher
    $stub = "$tmp\claude-stub.ps1"
    [IO.File]::WriteAllText($stub, '"dir=$env:CLAUDE_CONFIG_DIR|child=$env:CLAUDE_CODE_CHILD_SESSION|gb=$env:CLAUDE_CODE_GIT_BASH_PATH|cwd=$((Get-Location).ProviderPath)|args=$($args -join '','')" | Set-Content "$env:USERPROFILE\stub.out"; exit 7')
    $env:CLAUDE_BIN = $stub
    $env:CLAUDE_CODE_CHILD_SESSION = '1'
    $env:CLAUDE_CODE_GIT_BASH_PATH = 'D:\git\bin\bash.exe'
    function Stub { if (Test-Path "$tmp\stub.out") { return (Get-Content "$tmp\stub.out" -Raw).Trim() } return '' }
    function Clear-Stub { Remove-Item "$tmp\stub.out" -ErrorAction SilentlyContinue }

    $r = Run 'Invoke-Dossier.ps1' @('-p', 'hi') "$ws\clients\acme"
    Check 'cc passes the exit code' ($r.Code -eq 7) $r.Err
    Check 'cc in enterprise root uses its home' ((Stub) -like "dir=$tmp\.claude-homes\acme|child=|*args=-p,hi") (Stub)
    Check 'cc keeps the user''s own CLAUDE_* settings' ((Stub) -like '*|gb=D:\git\bin\bash.exe|*') (Stub)
    Run 'Invoke-Dossier.ps1' @() "$ws\clients\widgetco" | Out-Null
    Check 'cc in no-seat root uses its home' ((Stub) -like "dir=$tmp\.claude-homes\widgetco|*")
    Run 'Invoke-Dossier.ps1' @() "$ws\hub" | Out-Null
    Check 'cc in hub leaves CLAUDE_CONFIG_DIR unset' ((Stub) -like 'dir=|*')
    Run 'Invoke-Dossier.ps1' @() $link | Out-Null
    Check 'cc through a junction uses the root''s home' ((Stub) -like "dir=$tmp\.claude-homes\acme|*") (Stub)
    Clear-Stub
    $r = Run 'Invoke-Dossier.ps1' @('-a', 'firm') "$ws\clients\acme"
    Check 'cc refuses another home in an enterprise root' ($r.Code -eq 1 -and $r.Err -match 'refused' -and -not (Test-Path "$tmp\stub.out"))
    $r = Run 'Invoke-Dossier.ps1' @('-a', 'firm') $link
    Check 'cc refuses another home through a junction' ($r.Code -eq 1 -and $r.Err -match 'refused')
    $r = Run 'Invoke-Dossier.ps1' @('-p', 'x', '--add-dir', "$ws\clients\acme") "$ws\hub"
    Check 'cc refuses --add-dir into an enterprise root' ($r.Code -eq 1 -and $r.Err -match 'add-dir')
    $r = Run 'Invoke-Dossier.ps1' @("--add-dir=$ws\clients\acme") "$ws\hub"
    Check 'cc refuses --add-dir= into an enterprise root' ($r.Code -eq 1)
    $r = Run 'Invoke-Dossier.ps1' @('--add-dir', "$ws\clients\widgetco", '-p', 'x') "$ws\hub"
    Check 'cc allows --add-dir into a no-seat root' ($r.Code -eq 7 -and (Stub) -like "*args=--add-dir,$ws\clients\widgetco,-p,x") (Stub)
    $r = Run 'Invoke-Dossier.ps1' @('-a', 'firm') "$ws\clients\widgetco"
    Check 'cc allows another home in a no-seat root, with a note' ($r.Code -eq 7 -and $r.Err -match 'belongs to')
    Run 'Invoke-Dossier.ps1' @('-a', 'acme', '--at-root', '-p', 'x') "$ws\hub" | Out-Null
    Check 'cc --at-root starts in the root' ((Stub) -like "*cwd=$ws\clients\acme|*")
    $raw = Get-Content -Raw $env:DOSSIER_CONFIG | ConvertFrom-Json -AsHashtable; $raw.firm.key = 'studio'
    [IO.File]::WriteAllText($env:DOSSIER_CONFIG, ($raw | ConvertTo-Json -Depth 8))
    $r = Run 'Invoke-Dossier.ps1' @('-a', 'studio') "$ws\hub"
    Check 'a custom firm key works with cc -a' ($r.Code -eq 7 -and (Stub) -like 'dir=|*') $r.Err
    Write-Registry @($acme, $widget)
    $r = Run 'Invoke-Dossier.ps1' @('-a', 'nope')
    Check 'cc rejects an unknown key' ($r.Code -eq 1)

    # sessions starting other homes
    $env:CLAUDECODE = '1'
    Clear-Stub
    $r = Run 'Invoke-Dossier.ps1' @('-a', 'acme', '--at-root', '-p', 'x') "$ws\hub"
    Check 'cc refuses enterprise handoff from another home''s session' ($r.Code -eq 1 -and $r.Err -match 'refused' -and -not (Test-Path "$tmp\stub.out"))
    $r = Run 'Invoke-Dossier.ps1' @('-a', 'widgetco', '--at-root', '-p', 'x') "$ws\hub"
    Check 'cc allows no-seat handoff from a session' ($r.Code -eq 7)
    $env:CLAUDE_CONFIG_DIR = "$tmp\.claude-homes\acme"
    $r = Run 'Invoke-Dossier.ps1' @('-p', 'x') "$ws\clients\acme"
    Check 'cc allows an enterprise session to start its own home' ($r.Code -eq 7)
    $r = Run 'Invoke-Dossier.ps1' @('-a', 'firm', '--at-root', '-p', 'x') "$ws\clients\acme"
    Check 'cc refuses an enterprise session starting firm' ($r.Code -eq 1 -and $r.Err -match 'refused')
    $r = Run 'Invoke-Dossier.ps1' @('-a', 'widgetco', '--at-root', '-p', 'x') "$ws\clients\acme"
    Check 'cc refuses an enterprise session starting another client' ($r.Code -eq 1 -and $r.Err -match 'refused')
    Remove-Item Env:\CLAUDECODE, Env:\CLAUDE_CONFIG_DIR

    # logins and providers
    Set-Login "$tmp\.claude-homes\acme\.claude.json" 'me@firm.test'
    $r = Run 'Invoke-Dossier.ps1' @() "$ws\clients\acme"
    Check 'cc refuses an enterprise home on the wrong login' ($r.Code -eq 1 -and $r.Err -match 'refused.*logged in as me@firm.test')
    $r = Run 'Invoke-Dossier.ps1' @('--dossier-override') "$ws\clients\acme"
    Check 'cc --dossier-override starts it anyway' ($r.Code -eq 7 -and (Stub) -notmatch 'dossier-override')
    Set-Login "$tmp\.claude-homes\acme\.claude.json" 'me@acme.test'
    $env:ANTHROPIC_API_KEY = 'x'
    $r = Run 'Invoke-Dossier.ps1' @() "$ws\clients\acme"
    Check 'cc refuses an enterprise home with an API key set' ($r.Code -eq 1 -and $r.Err -match 'ANTHROPIC_API_KEY')
    $r = Run 'Invoke-Dossier.ps1' @() "$ws\clients\widgetco"
    Check 'cc only warns about an API key for a no-seat client' ($r.Code -eq 7 -and $r.Err -match 'WARNING: ANTHROPIC_API_KEY')
    Remove-Item Env:\ANTHROPIC_API_KEY
    $s = Read-Json "$tmp\.claude-homes\acme\settings.json"; $s.env = @{ ANTHROPIC_BASE_URL = 'https://proxy.test' }
    [IO.File]::WriteAllText("$tmp\.claude-homes\acme\settings.json", ($s | ConvertTo-Json -Depth 32))
    $r = Run 'Invoke-Dossier.ps1' @() "$ws\clients\acme"
    Check 'cc refuses an enterprise home whose settings set a base URL' ($r.Code -eq 1 -and $r.Err -match 'ANTHROPIC_BASE_URL')
    $s.Remove('env'); [IO.File]::WriteAllText("$tmp\.claude-homes\acme\settings.json", ($s | ConvertTo-Json -Depth 32))
    Remove-Item "$tmp\.claude-homes\acme\.claude.json"
    $r = Run 'Invoke-Dossier.ps1' @() "$ws\clients\acme"
    Check 'cc starts an enterprise home that isn''t logged in yet' ($r.Code -eq 7 -and $r.Err -match 'not logged in')

    # --- plain `claude` is routed too. A decoy claude first on PATH (exit 99) means a broken
    # route can never reach the real binary.
    $decoy = Join-Path $tmp 'decoy-bin'; New-Item -ItemType Directory $decoy | Out-Null
    [IO.File]::WriteAllText((Join-Path $decoy 'claude.cmd'), "@exit /b 99`r`n")
    [IO.File]::WriteAllText((Join-Path $decoy 'claude'), "#!/bin/sh`nexit 99`n")
    $env:PATH = "$decoy;$($saved['PATH'])"
    $dossierPs1 = Join-Path $win 'Dossier.ps1'
    Clear-Stub
    $r = RunExe 'pwsh' @('-NoProfile', '-Command', ". '$dossierPs1'; claude -p hi; exit `$LASTEXITCODE") "$ws\clients\acme"
    Check 'pwsh: claude routes to the folder''s home' ($r.Code -eq 7 -and (Stub) -like "dir=$tmp\.claude-homes\acme|*args=-p,hi") "$($r.Err) $(Stub)"
    $r = RunExe 'pwsh' @('-NoProfile', '-Command', ". '$dossierPs1'; claude --allowedTools Read,Grep; exit `$LASTEXITCODE") "$ws\clients\widgetco"
    Check 'pwsh: comma lists reach claude intact' ((Stub) -like '*args=--allowedTools,Read,Grep') (Stub)
    $env:DOSSIER_NO_CLAUDE_SHIM = '1'
    $r = RunExe 'pwsh' @('-NoProfile', '-Command', ". '$dossierPs1'; (Get-Command claude -ErrorAction SilentlyContinue).CommandType") "$ws\clients\acme"
    Check 'pwsh: opt-out leaves claude alone' ($r.Out.Trim() -ne 'Function') $r.Out
    Remove-Item Env:\DOSSIER_NO_CLAUDE_SHIM
    $gitBash = $null
    $d = Split-Path (@(Get-Command git -CommandType Application)[0].Source) -Parent
    while ($d -and -not $gitBash) { if (Test-Path "$d\bin\bash.exe") { $gitBash = "$d\bin\bash.exe" } else { $d = Split-Path $d -Parent } }
    if ($gitBash) {
        $dossierBash = (Join-Path (Split-Path $win -Parent) 'dossier.bash').Replace('\', '/')
        Clear-Stub
        $r = RunExe $gitBash @('-c', 'source "$1"; claude -p hi', '_', $dossierBash) "$ws\clients\widgetco"
        Check 'bash: claude routes to the folder''s home' ($r.Code -eq 7 -and (Stub) -like "dir=$tmp\.claude-homes\widgetco|*") "$($r.Err) $(Stub)"
    } else { Check 'bash: Git Bash found' $false }
    $env:PATH = $saved['PATH']
    Remove-Item Env:\CLAUDE_CODE_CHILD_SESSION, Env:\CLAUDE_BIN, Env:\CLAUDE_CODE_GIT_BASH_PATH

    # --- guard
    function Guard([string] $Cwd, [string] $ConfigDir) {
        if ($ConfigDir) { $env:CLAUDE_CONFIG_DIR = $ConfigDir } elseif (Test-Path Env:\CLAUDE_CONFIG_DIR) { Remove-Item Env:\CLAUDE_CONFIG_DIR }
        $r = Run 'dossier-guard.ps1' @() $tmp (@{ cwd = $Cwd; session_id = 's' } | ConvertTo-Json)
        if (Test-Path Env:\CLAUDE_CONFIG_DIR) { Remove-Item Env:\CLAUDE_CONFIG_DIR }
        return $r
    }
    Set-Login "$tmp\.claude.json" 'me@firm.test'
    Set-Login "$tmp\.claude-homes\acme\.claude.json" 'me@acme.test'
    Set-Login "$tmp\.claude-homes\widgetco\.claude.json" 'me@firm.test'
    $g = Guard "$ws\clients\acme\repo" ''
    Check 'guard: firm home in enterprise root is CRITICAL' ($g.Out -match 'CRITICAL' -and $g.Out -match 'enterprise-seat' -and $g.Code -eq 0)
    $g = Guard $link ''
    Check 'guard: through a junction is CRITICAL' ($g.Out -match 'CRITICAL')
    $g = Guard "$ws\clients\widgetco" ''
    Check 'guard: same login, wrong home is CRITICAL' ($g.Out -match 'CRITICAL')
    $g = Guard "$ws\clients\acme" "$tmp\.claude-homes\acme"
    Check 'guard: right home, right login is silent' ($g.Out -eq '') $g.Out
    Set-Login "$tmp\.claude-homes\acme\.claude.json" 'me@firm.test'
    $g = Guard "$ws\clients\acme" "$tmp\.claude-homes\acme"
    Check 'guard: wrong login is CRITICAL' ($g.Out -match 'CRITICAL.*logged in as me@firm.test')
    Set-Login "$tmp\.claude-homes\acme\.claude.json" 'me@acme.test'
    $g = Guard "$ws\stray" ''
    Check 'guard: unregistered folder is a NOTE' ($g.Out -match 'NOTE')
    $g = Guard "$ws\hub" ''
    Check 'guard: hub in firm home is silent' ($g.Out -eq '') $g.Out
    $env:DOSSIER_CONFIG = Join-Path $tmp 'missing.json'
    $g = Guard "$ws\hub" ''
    Check 'guard: a missing registry is reported' ($g.Out -match 'INDETERMINATE: no registry')
    $env:DOSSIER_CONFIG = Join-Path $tmp '.dossier.json'

    # --- doctor
    Remove-Item "$tmp\.claude\CLAUDE.md"
    Run 'Sync-Dossier.ps1' @('-Apply') | Out-Null
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor passes a clean setup' ($d.Code -eq 0) $d.Out
    New-Item -ItemType Directory -Path "$tmp\.claude\projects\$(Get-DsrProjectSlug "$ws\acme-old")\memory" -Force | Out-Null
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor finds client memory in the firm home (former root)' ($d.Code -eq 1 -and $d.Out -match "\[firm\] holds 1 project folder\(s\) for 'acme'") $d.Out
    Remove-Item -Recurse "$tmp\.claude\projects"
    New-Item -ItemType Junction -Path "$tmp\.claude-homes\widgetco\projects" -Target "$tmp\.claude" | Out-Null
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor finds a link into another home' ($d.Out -match 'links into another home')
    [IO.Directory]::Delete("$tmp\.claude-homes\widgetco\projects")
    [IO.File]::WriteAllText("$ws\CLAUDE.md", 'x')
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor finds a CLAUDE.md above a client root' ($d.Out -match 'above the client root')
    Remove-Item "$ws\CLAUDE.md"
    Set-Login "$tmp\.claude-homes\acme\.claude.json" 'me@firm.test'
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor finds a wrong login' ($d.Out -match 'FAIL\s+\[acme\] logged in as me@firm.test')
    Set-Login "$tmp\.claude-homes\acme\.claude.json" 'me@acme.test'
    foreach ($case in @(@{ n = 'root Read'; rule = $acmeRule }, @{ n = 'root Edit'; rule = $acmeRule.Replace('Read(', 'Edit(') }, @{ n = 'home'; rule = $acmeHomeRule })) {
        $s = Read-Json "$tmp\.claude\settings.json"; $orig = $s | ConvertTo-Json -Depth 32
        $s.permissions.deny = @($s.permissions.deny | Where-Object { $_ -ne $case.rule })
        [IO.File]::WriteAllText("$tmp\.claude\settings.json", ($s | ConvertTo-Json -Depth 32))
        $d = Run 'Test-Dossier.ps1'
        Check "doctor finds a missing $($case.n) deny rule" ($d.Code -eq 1 -and $d.Out -match 'missing deny rules')
        [IO.File]::WriteAllText("$tmp\.claude\settings.json", $orig)
    }

    # --- doctor: a key that prefixes another key (acme / acme-labs) is not a leak
    $labs = [ordered]@{ key = 'acme-labs'; root = '~/workspace/clients/acme-labs'; seat = 'none'; expectEmail = 'me@firm.test' }
    Write-Registry @($acme, $labs, $widget)
    Run 'Sync-Dossier.ps1' @('-Apply') | Out-Null
    Set-Login "$tmp\.claude-homes\acme-labs\.claude.json" 'me@firm.test'
    New-Item -ItemType Directory -Path "$tmp\.claude-homes\acme-labs\projects\$(Get-DsrProjectSlug "$ws\clients\acme-labs")" -Force | Out-Null
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor: prefix keys are not a false leak' ($d.Code -eq 0) $d.Out
} finally {
    if ($substDrive) { subst "${substDrive}:" /d 2>$null | Out-Null }
    foreach ($v in $saveVars) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
    Get-ChildItem -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue | Where-Object LinkType | ForEach-Object { [IO.Directory]::Delete($_.FullName) }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
