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

function Write-Registry($Clients, [string] $Personal = '~/.dossier/personal.md', [string[]] $Shared = @(), $Products = @(), $Agents = $null, $Permissions = $null) {
    $r = [ordered]@{
        workspaceRoot = '~/workspace'; personalRules = $Personal; sharedSkills = $Shared
        firm = [ordered]@{ hubRoot = '~/workspace/hub'; sandboxRoot = '~/workspace/sandbox'; expectEmail = 'me@firm.test' }
        clients = $Clients
        products = @($Products)
    }
    if ($Agents) { $r.agents = $Agents }
    if ($Permissions) { $r.permissions = $Permissions }
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
        @{ n = 'formerRoots covering the workspace'; c = @(Client @{ formerRoots = @('~') }) },
        @{ n = 'sharedPermissions that is not true or false'; c = @(Client @{ sharedPermissions = 'no' }) }
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
    Write-Registry @($widget) -Permissions @{ deny = @('Bash(curl:*)') }
    $threw = $false; try { Read-DsrRegistry | Out-Null } catch { $threw = $true }
    Check 'registry rejects shared permissions other than allow and ask' $threw

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
    $sg = @($fz.hooks.PreToolUse | Where-Object { ($_.hooks | ConvertTo-Json -Depth 4) -match 'dossier-shellguard' })
    Check 'firm shell guard hook on Bash and PowerShell' ($sg.Count -eq 1 -and $sg[0].matcher -eq 'Bash|PowerShell')
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

    # --- shared allow and ask rules: merged like deny, skipped where an entry opts out
    $fz = Read-Json "$tmp\.claude\settings.json"
    $fz.permissions.allow = @('Bash'); $fz.permissions.ask = @('Bash(hand:*)')
    [IO.File]::WriteAllText("$tmp\.claude\settings.json", ($fz | ConvertTo-Json -Depth 32))
    $acmeOut = [ordered]@{}; foreach ($k in $acme.Keys) { $acmeOut[$k] = $acme[$k] }; $acmeOut.sharedPermissions = $false
    $shared = [ordered]@{ allow = @('Bash', 'PowerShell'); ask = @('Bash(rm:*)', 'PowerShell(git clean:*)') }
    Write-Registry @($acmeOut, $widget) -Permissions $shared
    $r = Run 'Sync-Dossier.ps1' @('-Apply')
    Check 'sync with shared permissions exits 0' ($r.Code -eq 0) "$($r.Out) $($r.Err)"
    $wz = Read-Json "$tmp\.claude-homes\widgetco\settings.json"
    Check 'shared allow and ask reach an included home' ((@($wz.permissions.allow) -join ',') -eq 'Bash,PowerShell' -and (@($wz.permissions.ask) -join ',') -eq 'Bash(rm:*),PowerShell(git clean:*)') ($wz.permissions | ConvertTo-Json)
    $ac = Read-Json "$tmp\.claude-homes\acme\settings.json"
    Check 'an entry with sharedPermissions false gets none' (-not $ac.permissions.Contains('allow') -and -not $ac.permissions.Contains('ask'))
    $fz = Read-Json "$tmp\.claude\settings.json"
    Check 'a shared rule the home already had is not duplicated' ((@($fz.permissions.allow) -join ',') -eq 'Bash,PowerShell') (@($fz.permissions.allow) -join ',')
    Check 'hand-added ask rule survives' ('Bash(hand:*)' -in $fz.permissions.ask -and 'Bash(rm:*)' -in $fz.permissions.ask)
    Check 'only rules Sync added are tracked' ((@((Read-Json "$tmp\.claude\dossier.managed.json").allow) -join ',') -eq 'PowerShell')
    $r = Run 'Sync-Dossier.ps1' @('-Apply')
    Check 'sync with shared permissions is idempotent' ($r.Out -match 'In sync\.') $r.Out

    $wz.permissions.allow = @($wz.permissions.allow) + 'Read(mine)'
    [IO.File]::WriteAllText("$tmp\.claude-homes\widgetco\settings.json", ($wz | ConvertTo-Json -Depth 32))
    Write-Registry @($acmeOut, $widget) -Permissions ([ordered]@{ allow = @('PowerShell'); ask = @('Bash(rm:*)') })
    Run 'Sync-Dossier.ps1' @('-Apply') | Out-Null
    $wz = Read-Json "$tmp\.claude-homes\widgetco\settings.json"
    Check 'a rule dropped from the registry goes where Sync added it' ('Bash' -notin $wz.permissions.allow -and 'PowerShell(git clean:*)' -notin $wz.permissions.ask)
    Check 'hand-added allow rule survives a registry change' ('Read(mine)' -in $wz.permissions.allow -and 'PowerShell' -in $wz.permissions.allow)
    $fz = Read-Json "$tmp\.claude\settings.json"
    Check 'a dropped rule the home had by hand stays' ('Bash' -in $fz.permissions.allow -and 'PowerShell' -in $fz.permissions.allow)

    Write-Registry @($acme, $widget)
    Run 'Sync-Dossier.ps1' @('-Apply') | Out-Null
    $fz = Read-Json "$tmp\.claude\settings.json"; $wz = Read-Json "$tmp\.claude-homes\widgetco\settings.json"
    Check 'removing shared permissions keeps only hand-added rules' ((@($fz.permissions.allow) -join ',') -eq 'Bash' -and (@($fz.permissions.ask) -join ',') -eq 'Bash(hand:*)' -and (@($wz.permissions.allow) -join ',') -eq 'Read(mine)' -and -not $wz.permissions.Contains('ask')) "$(@($fz.permissions.allow) -join ',') | $(@($fz.permissions.ask) -join ',') | $(@($wz.permissions.allow) -join ',')"
    $fz.permissions.Remove('allow'); $fz.permissions.Remove('ask')
    [IO.File]::WriteAllText("$tmp\.claude\settings.json", ($fz | ConvertTo-Json -Depth 32))
    $wz.permissions.Remove('allow')
    [IO.File]::WriteAllText("$tmp\.claude-homes\widgetco\settings.json", ($wz | ConvertTo-Json -Depth 32))

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
        Clear-Stub
        $r = RunExe $gitBash @('-c', 'source "$1"; bash -c "$(declare -f cc claude); claude -p hi"', '_', $dossierBash) "$ws\clients\widgetco"
        Check 'bash: claude works when only its functions are carried over' ($r.Code -eq 7 -and (Stub) -like "dir=$tmp\.claude-homes\widgetco|*") "$($r.Err) $(Stub)"
        Clear-Stub
        $r = RunExe $gitBash @('-c', 'cd "$(dirname "$1")"; source ./dossier.bash; cd "$2"; claude -p hi', '_', $dossierBash, "$ws\clients\widgetco".Replace('\', '/')) $tmp
        Check 'bash: relative source then cd still finds the launcher' ($r.Code -eq 7 -and (Stub) -like "dir=$tmp\.claude-homes\widgetco|*") "$($r.Err) $(Stub)"
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

    # --- shell guard
    function Shell([string] $Command, [string] $Cwd, [string] $ConfigDir) {
        if ($ConfigDir) { $env:CLAUDE_CONFIG_DIR = $ConfigDir } elseif (Test-Path Env:\CLAUDE_CONFIG_DIR) { Remove-Item Env:\CLAUDE_CONFIG_DIR }
        $r = Run 'dossier-shellguard.ps1' @() $tmp (@{ tool_name = 'PowerShell'; tool_input = @{ command = $Command }; cwd = $Cwd } | ConvertTo-Json)
        if (Test-Path Env:\CLAUDE_CONFIG_DIR) { Remove-Item Env:\CLAUDE_CONFIG_DIR }
        return $r
    }
    $acmeFile = "$ws\clients\acme\a"
    $posix = $acmeFile.Substring(0, 1).ToLower() + $acmeFile.Substring(2).Replace('\', '/')
    $shellCases = @(
        @{ n = 'absolute path'; c = "Get-Content $acmeFile"; d = $ws; deny = $true }
        @{ n = 'Git Bash path'; c = "cat /$posix"; d = $ws; deny = $true }
        @{ n = 'WSL path'; c = "cat /mnt/$posix"; d = $ws; deny = $true }
        @{ n = 'escaped path in a script'; c = "python -c `"open('$($acmeFile.Replace('\', '\\'))')`""; d = $ws; deny = $true }
        @{ n = '$env:USERPROFILE'; c = 'gc $env:USERPROFILE\.claude-homes\acme\CLAUDE.md'; d = $ws; deny = $true }
        @{ n = '~'; c = 'cat ~/workspace/clients/acme/a'; d = $ws; deny = $true }
        @{ n = 'relative path'; c = 'type clients\acme\a.txt'; d = $ws; deny = $true }
        @{ n = 'parent-relative path'; c = 'cat ../acme/a'; d = "$ws\clients\widgetco"; deny = $true }
        @{ n = 'wildcard over a denied root'; c = 'cat ../*/a'; d = "$ws\clients\widgetco"; deny = $true }
        @{ n = 'recursive search from above'; c = 'rg TODO'; d = $ws; deny = $true }
        @{ n = 'recursive search naming a parent'; c = "Get-ChildItem -Recurse $ws"; d = "$ws\hub"; deny = $true }
        @{ n = 'recursive search in an allowed folder'; c = 'rg TODO clients\widgetco'; d = $ws; deny = $false }
        @{ n = 'ordinary command'; c = 'git status; git log -3'; d = "$ws\hub"; deny = $false }
        @{ n = 'whole segments only'; c = "Get-Content $ws\acme-old\a"; d = $ws; deny = $false }
        @{ n = 'URL'; c = 'curl https://example.test/clients/acme'; d = $ws; deny = $false }
        @{ n = 'wildcard in an allowed folder'; c = 'ls *.md'; d = "$ws\hub"; deny = $false }
    )
    foreach ($c in $shellCases) {
        $r = Shell $c.c $c.d ''
        $isDenied = $r.Out -match '"permissionDecision":"deny"'
        Check "shell guard: $($c.n) $(if ($c.deny) { 'denied' } else { 'allowed' })" ($r.Code -eq 0 -and $isDenied -eq $c.deny) "$($c.c) -> $($r.Out) $($r.Err)"
    }
    $r = Shell "cat $ws\hub\notes.md" "$ws\clients\acme" "$tmp\.claude-homes\acme"
    Check 'shell guard: a client home keeps out of the hub' ($r.Out -match '"deny"') $r.Out
    $r = Shell "cat $acmeFile" "$ws\clients\acme" "$tmp\.claude-homes\acme"
    Check 'shell guard: a client reads its own root' ($r.Out -eq '') $r.Out
    $r = Shell "cat $ws\anything" $ws "$tmp\no-such-home"
    Check 'shell guard: a home without settings lets commands through' ($r.Code -eq 0 -and $r.Out -eq '') $r.Out

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
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor: a clean workspace has no loose items' ($d.Out -notmatch 'in no registered root') $d.Out
    New-Item -ItemType Directory -Path "$ws\clients\.claude" -Force | Out-Null
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor finds a loose item inside a folder that holds roots' ($d.Out -match 'WARN\s+1 item\(s\).*clients\\\.claude') $d.Out
    Remove-Item "$ws\clients\.claude"
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
    $s = Read-Json "$tmp\.claude\settings.json"; $orig = $s | ConvertTo-Json -Depth 32
    $s.hooks.Remove('PreToolUse')
    [IO.File]::WriteAllText("$tmp\.claude\settings.json", ($s | ConvertTo-Json -Depth 32))
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor finds a missing shell guard hook' ($d.Code -eq 1 -and $d.Out -match 'shell guard hook not wired')
    [IO.File]::WriteAllText("$tmp\.claude\settings.json", $orig)

    Write-Registry @($acmeOut, $widget) -Permissions $shared
    Run 'Sync-Dossier.ps1' @('-Apply') | Out-Null
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor passes a home with every shared rule' ($d.Code -eq 0 -and $d.Out -match 'ok\s+\[widgetco\] shared allow and ask rules in place') $d.Out
    Check 'doctor skips shared rules for an opted-out home' ($d.Out -notmatch '\[acme\] (missing )?shared') $d.Out
    $wzFile = "$tmp\.claude-homes\widgetco\settings.json"
    $s = Read-Json $wzFile; $orig = $s | ConvertTo-Json -Depth 32
    $s.permissions.ask = @($s.permissions.ask | Where-Object { $_ -ne 'Bash(rm:*)' })
    [IO.File]::WriteAllText($wzFile, ($s | ConvertTo-Json -Depth 32))
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor fails a home missing a shared ask rule' ($d.Code -eq 1 -and $d.Out -match 'FAIL\s+\[widgetco\] missing shared ask rules: Bash\(rm:\*\)') $d.Out
    [IO.File]::WriteAllText($wzFile, $orig)
    $s = Read-Json $wzFile
    $s.permissions.allow = @($s.permissions.allow | Where-Object { $_ -ne 'PowerShell' })
    [IO.File]::WriteAllText($wzFile, ($s | ConvertTo-Json -Depth 32))
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor warns about a home missing a shared allow rule' ($d.Out -match 'WARN\s+\[widgetco\] missing shared allow rules: PowerShell' -and $d.Out -notmatch '\[widgetco\] missing shared ask') $d.Out
    [IO.File]::WriteAllText($wzFile, $orig)
    Write-Registry @($acme, $widget)
    Run 'Sync-Dossier.ps1' @('-Apply') | Out-Null

    # --- doctor: a key that prefixes another key (acme / acme-labs) is not a leak
    $labs = [ordered]@{ key = 'acme-labs'; root = '~/workspace/clients/acme-labs'; seat = 'none'; expectEmail = 'me@firm.test' }
    Write-Registry @($acme, $labs, $widget)
    Run 'Sync-Dossier.ps1' @('-Apply') | Out-Null
    Set-Login "$tmp\.claude-homes\acme-labs\.claude.json" 'me@firm.test'
    New-Item -ItemType Directory -Path "$tmp\.claude-homes\acme-labs\projects\$(Get-DsrProjectSlug "$ws\clients\acme-labs")" -Force | Out-Null
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor: prefix keys are not a false leak' ($d.Code -eq 0) $d.Out

    # --- products
    $prod = [ordered]@{ key = 'base'; name = 'Base'; root = '~/workspace/products/base' }
    function With([System.Collections.IDictionary] $Base, [hashtable] $Extra) { $c = [ordered]@{}; foreach ($k in $Base.Keys) { $c[$k] = $Base[$k] }; foreach ($k in $Extra.Keys) { $c[$k] = $Extra[$k] }; return $c }
    $badProd = @(
        @{ n = 'basedOn an unknown product'; c = @(Client @{ basedOn = @('nope') }); p = @($prod) },
        @{ n = 'product key equal to a client key'; c = @(Client @{ key = 'base' }); p = @($prod) },
        @{ n = 'product root inside a client root'; c = @($widget); p = @(With $prod @{ root = '~/workspace/clients/widgetco/base' }) },
        @{ n = 'product home inside ~/.claude'; c = @($widget); p = @(With $prod @{ home = '~/.claude/base' }) },
        @{ n = 'product enterpriseRead that isn''t a boolean'; c = @($widget); p = @(With $prod @{ enterpriseRead = 'yes' }) },
        @{ n = 'a repo remote starting with -'; c = @($widget); p = @(With $prod @{ repos = @(@{ remote = '--upload-pack=x' }) }) },
        @{ n = 'clientRead with ..'; c = @($widget); p = @(With $prod @{ clientRead = @('src/../..') }) },
        @{ n = 'clientRead that is absolute'; c = @($widget); p = @(With $prod @{ clientRead = @('C:/x') }) },
        @{ n = 'clientRead with a wildcard'; c = @($widget); p = @(With $prod @{ clientRead = @('src/*') }) }
    )
    foreach ($b in $badProd) {
        Write-Registry $b.c -Products $b.p
        $threw = $false; try { Read-DsrRegistry | Out-Null } catch { $threw = $true }
        Check "registry rejects $($b.n)" $threw
    }
    $raw = Get-Content -Raw $env:DOSSIER_CONFIG | ConvertFrom-Json -AsHashtable; $raw.templates = @(); $raw.Remove('products')
    [IO.File]::WriteAllText($env:DOSSIER_CONFIG, ($raw | ConvertTo-Json -Depth 8))
    $threw = $false; try { Read-DsrRegistry | Out-Null } catch { $threw = $_.Exception.Message -match 'now .products' }
    Check 'registry rejects the old templates section by name' $threw

    $src = Join-Path $tmp 'src'
    RunExe 'git' @('init', '-q', $src) $tmp | Out-Null
    [IO.File]::WriteAllText("$src\README.md", 'base')
    RunExe 'git' @('-C', $src, 'add', '.') $tmp | Out-Null
    RunExe 'git' @('-C', $src, '-c', 'user.name=t', '-c', 'user.email=t@t.test', 'commit', '-q', '-m', 'init') $tmp | Out-Null
    $prod = With $prod @{ clientRead = @('src/code'); repos = @(@{ remote = $src }) }
    $acmeB = With $acme @{ basedOn = @('base'); repos = @(@{ remote = $src }) }
    $widgetB = With $widget @{ basedOn = @('base') }
    $beta = [ordered]@{ key = 'beta'; name = 'Beta'; root = '~/workspace/clients/beta'; seat = 'none'; expectEmail = 'me@firm.test'; basedOn = @('base') }
    $gamma = [ordered]@{ key = 'gamma'; root = '~/workspace/clients/gamma'; seat = 'none'; expectEmail = 'me@firm.test' }
    Write-Registry @($acmeB, $widgetB, $beta, $gamma) -Products @($prod)
    $reg = Read-DsrRegistry
    Check 'owner: a product root is the product' ((Find-DsrOwner $reg "$ws\products\base\src").Entry.Key -eq 'base')
    Check 'a product logs in to the firm account by default' ((Find-DsrEntry $reg 'base').ExpectEmail -eq 'me@firm.test')

    $r = Run 'Sync-Dossier.ps1' @('-Apply')
    Check 'sync with a product exits 0' ($r.Code -eq 0) "$($r.Out) $($r.Err)"
    Check 'sync warns about an enterprise client the product blocks' ($r.Out -match "warn\s+'acme' is based on 'base'") $r.Out
    $pRoot = "$ws\products\base"; $pHome = "$tmp\.claude-homes\base"
    Check 'sync created the product root, home and stub' ((Test-Path $pHome) -and (Get-Content -Raw "$pRoot\CLAUDE.md") -match 'Base: product notes')
    $pRootRule = Rule $pRoot; $pRootEdit = $pRootRule.Replace('Read(', 'Edit(')
    $pHomeRule = Rule $pHome; $pHomeEdit = $pHomeRule.Replace('Read(', 'Edit(')
    $fz = Read-Json "$tmp\.claude\settings.json"
    Check 'firm reads the product and its memory' (@($fz.permissions.additionalDirectories) -contains $pRoot.Replace('\', '/') -and @($fz.permissions.additionalDirectories) -contains "$pHome\projects".Replace('\', '/'))
    Check 'firm may read but not edit the product home' ($pHomeEdit -in $fz.permissions.deny -and $pHomeRule -notin $fz.permissions.deny)
    Check 'firm is kept out of the product login' ((Rule "$pHome\.credentials.json" -File) -in $fz.permissions.deny -and (Rule "$pHome\.claude.json" -File) -in $fz.permissions.deny)
    Check 'firm has no deny rule on the product root' ($pRootRule -notin $fz.permissions.deny -and $pRootEdit -notin $fz.permissions.deny)
    $bz = Read-Json "$pHome\settings.json"
    Check 'product home is kept out of every client and the hub' ($widgetRule -in $bz.permissions.deny -and $acmeRule -in $bz.permissions.deny -and $hubRule -in $bz.permissions.deny -and $firmHomeRule -in $bz.permissions.deny)
    Check 'product home may read its own root' ($pRootRule -notin $bz.permissions.deny)
    $wz = Read-Json "$tmp\.claude-homes\widgetco\settings.json"
    Check 'client: product root edit denied, not read' ($pRootEdit -in $wz.permissions.deny -and $pRootRule -notin $wz.permissions.deny)
    Check 'client: product home denied' ($pHomeRule -in $wz.permissions.deny)
    Check 'client: an uncloned repo on the clientRead path is denied' ((Rule "$pRoot\src") -in $wz.permissions.deny) ($wz.permissions.deny -join "`n")
    Check 'client: the product stub CLAUDE.md is denied' ((Rule "$pRoot\CLAUDE.md" -File) -in $wz.permissions.deny)
    $ac = Read-Json "$tmp\.claude-homes\acme\settings.json"
    Check 'enterprise client is blocked without enterpriseRead' ($pRootRule -in $ac.permissions.deny -and $pRootEdit -in $ac.permissions.deny)
    $gz = Read-Json "$tmp\.claude-homes\gamma\settings.json"
    Check 'client not based on the product is denied it' ($pRootRule -in $gz.permissions.deny)
    Check 'based-on client stub names the product and its paths' ((Get-Content -Raw "$ws\clients\beta\CLAUDE.md") -match "## Products[\s\S]*Base: ``$([regex]::Escape("$pRoot\src\code"))``")
    $hub = Get-Content -Raw "$ws\hub\CLAUDE.md"
    Check 'hub table lists the product and who uses it' ($hub -match '\| base \| Base \| .* \| `src\\code` \| no \| acme \(blocked: enterprise\), widgetco, beta \|') $hub
    $r = Run 'Sync-Dossier.ps1' @('-Apply')
    Check 'sync with products is idempotent' ($r.Out -match 'In sync\.') $r.Out

    # import, then the clientRead path appears
    $r = Run 'Import-Dossier.ps1' @('-Key', 'base')
    Check 'import dry run clones nothing' ($r.Code -eq 0 -and $r.Out -match 'plan\s+clone' -and -not (Test-Path "$pRoot\src")) "$($r.Out) $($r.Err)"
    $r = Run 'Import-Dossier.ps1' @('-Key', 'base', '-Apply')
    Check 'import clones the product repo' ($r.Code -eq 0 -and (Test-Path "$pRoot\src\README.md")) "$($r.Out) $($r.Err)"
    Check 'import: the doctor flags the product as changed since Sync' ($r.Out -match 'product base changed on disk') $r.Out
    $wz = Read-Json "$tmp\.claude-homes\widgetco\settings.json"
    Check 'import: the new clone stays denied until Sync' ((Rule "$pRoot\src") -in $wz.permissions.deny)
    $r = Run 'Import-Dossier.ps1' @('-Key', 'base', '-Apply')
    Check 'import is idempotent' ($r.Out -match 'already cloned') $r.Out
    $r = Run 'Import-Dossier.ps1' @('-Key', 'nope')
    Check 'import rejects an unknown key' ($r.Code -eq 1)
    $env:CLAUDECODE = '1'
    $r = Run 'Import-Dossier.ps1' @('-Key', 'acme', '-Apply')
    Check 'import refuses an enterprise client from a session' ($r.Code -eq 1 -and $r.Err -match 'Refused' -and -not (Test-Path "$ws\clients\acme\src"))
    Remove-Item Env:\CLAUDECODE

    New-Item -ItemType Directory -Path "$pRoot\src\code" | Out-Null
    [IO.File]::WriteAllText("$pRoot\src\code\app.txt", 'code')
    [IO.File]::WriteAllText("$pRoot\src\secret.md", 'internal')
    Run 'Sync-Dossier.ps1' @('-Apply') | Out-Null
    $wz = Read-Json "$tmp\.claude-homes\widgetco\settings.json"
    Check 'client: clientRead path readable' (@($wz.permissions.deny | Where-Object { $_ -like "Read($(ConvertTo-DsrRulePath "$pRoot\src\code")*" }).Count -eq 0) ($wz.permissions.deny -join "`n")
    Check 'client: siblings of the clientRead path denied' ((Rule "$pRoot\src\secret.md" -File) -in $wz.permissions.deny -and (Rule "$pRoot\src\README.md" -File) -in $wz.permissions.deny -and (Rule "$pRoot\src\.git") -in $wz.permissions.deny)
    Check 'client: the stale whole-repo deny is gone' ((Rule "$pRoot\src") -notin $wz.permissions.deny)
    Check 'client: clientRead path in additionalDirectories' (@($wz.permissions.additionalDirectories) -contains "$pRoot\src\code".Replace('\', '/'))
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor passes a clean setup with products' ($d.Code -eq 0) $d.Out
    Check 'doctor warns about the blocked enterprise client' ($d.Out -match "WARN\s+\[acme\] is based on product 'base'") $d.Out

    # shell guard
    $wHome = "$tmp\.claude-homes\widgetco"
    $prodCases = @(
        @{ n = 'read inside clientRead'; c = "Get-Content $pRoot\src\code\app.txt"; d = "$ws\clients\widgetco"; deny = $false }
        @{ n = 'read a sibling'; c = "Get-Content $pRoot\src\secret.md"; d = "$ws\clients\widgetco"; deny = $true }
        @{ n = 'read the git folder'; c = "cat $pRoot\src\.git\config"; d = "$ws\clients\widgetco"; deny = $true }
        @{ n = 'search from the product root'; c = 'rg TODO'; d = $pRoot; deny = $true }
        @{ n = 'search inside clientRead'; c = 'rg TODO'; d = "$pRoot\src\code"; deny = $false }
        @{ n = 'write inside clientRead'; c = "Set-Content $pRoot\src\code\app.txt x"; d = "$ws\clients\widgetco"; deny = $true }
        @{ n = 'git commit inside clientRead'; c = 'git commit -am x'; d = "$pRoot\src\code"; deny = $true }
    )
    foreach ($c in $prodCases) {
        $r = Shell $c.c $c.d $wHome
        $isDenied = $r.Out -match '"permissionDecision":"deny"'
        Check "shell guard, client on a product: $($c.n) $(if ($c.deny) { 'denied' } else { 'allowed' })" ($r.Code -eq 0 -and $isDenied -eq $c.deny) "$($c.c) -> $($r.Out) $($r.Err)"
    }
    $r = Shell "cat $pRoot\src\code\app.txt" "$ws\clients\gamma" "$tmp\.claude-homes\gamma"
    Check 'shell guard: a client not based on the product can''t read it' ($r.Out -match '"deny"') $r.Out
    $r = Shell "Set-Content $pRoot\src\secret.md x" "$ws\hub" ''
    Check 'shell guard: the firm may edit a product' ($r.Out -eq '') $r.Out
    $r = Shell "cat $ws\clients\widgetco\CLAUDE.md" $pRoot $pHome
    Check 'shell guard: a product home can''t read a client' ($r.Out -match '"deny"') $r.Out

    # drift: a folder added beside clientRead is caught, and Sync closes it
    New-Item -ItemType Directory -Path "$pRoot\src\internal" | Out-Null
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor finds a product folder added since Sync' ($d.Code -eq 1 -and $d.Out -match 'product base changed on disk') $d.Out
    Run 'Sync-Dossier.ps1' @('-Apply') | Out-Null
    $d = Run 'Test-Dossier.ps1'
    Check 'sync closes the new folder' ($d.Code -eq 0 -and (Rule "$pRoot\src\internal") -in (Read-Json "$wHome\settings.json").permissions.deny) $d.Out

    # enterpriseRead opens clientRead to the enterprise client
    $prod.enterpriseRead = $true
    Write-Registry @($acmeB, $widgetB, $beta, $gamma) -Products @($prod)
    Run 'Sync-Dossier.ps1' @('-Apply') | Out-Null
    $ac = Read-Json "$tmp\.claude-homes\acme\settings.json"
    Check 'enterpriseRead: enterprise client reads clientRead only' ($pRootEdit -in $ac.permissions.deny -and $pRootRule -notin $ac.permissions.deny -and (Rule "$pRoot\src\secret.md" -File) -in $ac.permissions.deny)
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor stops warning once enterpriseRead is set' ($d.Out -notmatch 'is based on product') $d.Out

    # launcher
    $env:CLAUDE_BIN = $stub
    Clear-Stub
    Run 'Invoke-Dossier.ps1' @('-a', 'base', '--at-root', '-p', 'x') $tmp | Out-Null
    Check 'cc -a <product> --at-root: its home in its root' ((Stub) -like "dir=$pHome|*cwd=$pRoot|*") (Stub)
    Run 'Invoke-Dossier.ps1' @() "$pRoot\src" | Out-Null
    Check 'cc in a product uses its home' ((Stub) -like "dir=$pHome|*") (Stub)
    Remove-Item Env:\CLAUDE_BIN

    # doctor: memory and ancestors
    New-Item -ItemType Directory -Path "$wHome\projects\$(Get-DsrProjectSlug "$pRoot\src")" -Force | Out-Null
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor finds product memory in a client home' ($d.Code -eq 1 -and $d.Out -match "\[widgetco\] holds 1 project folder\(s\) for 'base'") $d.Out
    Remove-Item -Recurse "$wHome\projects"
    [IO.File]::WriteAllText("$ws\products\CLAUDE.md", 'x')
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor finds a CLAUDE.md above a product root' ($d.Out -match 'above the product root')
    Remove-Item "$ws\products\CLAUDE.md"

    # a registered repo beside clientRead is denied before it is cloned
    $prod.repos = @(@{ remote = $src }, @{ remote = $src; dir = 'later' })
    Write-Registry @($acmeB, $widgetB, $beta, $gamma) -Products @($prod)
    $reg = Read-DsrRegistry
    Check 'an uncloned repo beside clientRead is denied ahead of time' (@(Get-DsrProductReadDenies (Find-DsrEntry $reg 'base') | Where-Object { $_.Path -eq "$pRoot\later" }).Count -eq 1)

    # --- client base repos
    function GitIn([string] $Dir, [string[]] $GitArgs) { return (RunExe 'git' (@('-C', $Dir, '-c', 'user.name=t', '-c', 'user.email=t@t.test') + $GitArgs) $tmp) }
    function Commit([string] $Dir, [string] $File) { [IO.File]::WriteAllText("$Dir\$File", $File); GitIn $Dir @('add', '.') | Out-Null; GitIn $Dir @('commit', '-q', '-m', $File) | Out-Null; return (GitIn $Dir @('rev-parse', 'HEAD')).Out.Trim() }
    $src2 = Join-Path $tmp 'src2'
    RunExe 'git' @('init', '-q', $src2) $tmp | Out-Null
    $c1 = Commit $src2 'a.txt'; $c2 = Commit $src2 'b.txt'
    $wApp = "$ws\clients\widgetco\w-app"
    RunExe 'git' @('clone', '-q', $src2, $wApp) $tmp | Out-Null
    $c3 = Commit $src2 'c.txt'

    $core = [ordered]@{ key = 'core'; name = 'Core'; root = '~/workspace/products/core'; clientRead = @('app'); repos = @(@{ remote = $src2; dir = 'app' }) }
    $fork = @{ remote = $src2; dir = 'w-app'; from = @{ product = 'core'; repo = 'app' } }
    $badFrom = @(
        @{ n = 'a fork of a product the client isn''t based on'; c = With $widget @{ basedOn = @('base'); repos = @($fork) } },
        @{ n = 'a fork of a repo the product doesn''t have'; c = With $widget @{ basedOn = @('core'); repos = @(@{ remote = $src2; dir = 'w-app'; from = @{ product = 'core'; repo = 'nope' } }) } },
        @{ n = 'a fork with no repo'; c = With $widget @{ basedOn = @('core'); repos = @(@{ remote = $src2; dir = 'w-app'; from = @{ product = 'core' } }) } }
    )
    foreach ($b in $badFrom) {
        Write-Registry @($b.c) -Products @($prod, $core)
        $threw = $false; try { Read-DsrRegistry | Out-Null } catch { $threw = $true }
        Check "registry rejects $($b.n)" $threw
    }

    $widgetC = With $widget @{ basedOn = @('base', 'core'); repos = @($fork) }
    $betaC = With $beta @{ basedOn = @('base', 'core') }
    Write-Registry @($acmeB, $widgetC, $betaC, $gamma) -Products @($prod, $core)
    $r = Run 'Import-Dossier.ps1' @('-Key', 'core', '-Apply')
    Check 'import clones the product code repo' ($r.Code -eq 0 -and (Test-Path "$ws\products\core\app\c.txt")) "$($r.Out) $($r.Err)"
    $wMd = "$ws\clients\widgetco\CLAUDE.md"
    [IO.File]::WriteAllText($wMd, ((Get-Content -Raw $wMd) -replace '<!-- (BEGIN|END) GENERATED: Sync-Dossier products -->', ''))
    $r = Run 'Sync-Dossier.ps1' @('-Apply')
    Check 'sync with forks exits 0' ($r.Code -eq 0) "$($r.Out) $($r.Err)"
    Check 'sync notes a client CLAUDE.md without products markers' ($r.Out -match 'note\s+.*widgetco\\CLAUDE\.md has no products markers') $r.Out
    Set-Login "$tmp\.claude-homes\gamma\.claude.json" 'me@firm.test'
    $statusFile = "$wHome\dossier.products.json"
    $st = Read-Json $statusFile
    $sc = $st.products | Where-Object { $_.key -eq 'core' }
    $f = $sc.forks[0]
    Check 'status: the fork''s base is the newest shared commit' ($f.state -eq 'ok' -and $f.base -eq $c2 -and $f.behind -eq 1) ($st | ConvertTo-Json -Depth 10)
    Check 'status: changed file names since the base' (@($f.changed) -contains 'c.txt' -and @($f.changed).Count -eq 1)
    Check 'status: the product repo head' ($sc.repos[0].head -eq $c3)
    Check 'status: no commit messages' ((Get-Content -Raw $statusFile) -notmatch '"message"|"subject"')
    $sb = $st.products | Where-Object { $_.key -eq 'base' }
    Check 'status: a product with only part readable lists no repo heads' ($sb.readable -and @($sb.repos).Count -eq 0)
    Check 'status: none for a client based on nothing' (-not (Test-Path "$tmp\.claude-homes\gamma\dossier.products.json"))
    Check 'skill copied into a based-on client home' ((Get-Content -Raw "$wHome\skills\dossier-product\SKILL.md") -match 'name: dossier-product')
    Check 'skill not in a client based on nothing' (-not (Test-Path "$tmp\.claude-homes\gamma\skills\dossier-product"))
    Check 'client CLAUDE.md products section stays current' ((Get-Content -Raw "$ws\clients\beta\CLAUDE.md") -match '- Core: `[^`]*products\\core\\app`')
    $hub = Get-Content -Raw "$ws\hub\CLAUDE.md"
    Check 'hub table shows a no-seat fork''s base and distance' ($hub -match "widgetco \(``w-app`` @ $($c2.Substring(0, 7)), 1 behind\)") $hub
    $r = Run 'Sync-Dossier.ps1' @('-Apply')
    Check 'sync with forks is idempotent' ($r.Out -match 'In sync\.') $r.Out
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor passes forks of a fully readable repo' ($d.Code -eq 0 -and $d.Out -notmatch 'shares no commit') $d.Out

    $g = Guard $wApp $wHome
    $ctx = try { ($g.Out | ConvertFrom-Json).hookSpecificOutput.additionalContext } catch { '' }
    Check 'guard: a based-on client gets a model-only product note' ($ctx -match "fork of core/app at $($c2.Substring(0, 7)); the product has 1 newer commit" -and $ctx -match 'Changed: c\.txt' -and $g.Out -notmatch 'systemMessage') $g.Out
    $g = Guard "$ws\clients\gamma" "$tmp\.claude-homes\gamma"
    Check 'guard: a client based on nothing stays silent' ($g.Out -eq '') $g.Out

    # fetched but not merged doesn't move the base; merging does
    $coreApp = "$ws\products\core\app"
    $c4 = Commit $coreApp 'd.txt'
    GitIn $wApp @('fetch', '-q', $coreApp, 'HEAD') | Out-Null
    Run 'Sync-Dossier.ps1' @('-Apply') | Out-Null
    $f = ((Read-Json $statusFile).products | Where-Object { $_.key -eq 'core' }).forks[0]
    Check 'a fetch without a merge leaves the base' ($f.base -eq $c2 -and $f.behind -eq 2) ($f | ConvertTo-Json)
    GitIn $wApp @('merge', '-q', '--ff-only', 'FETCH_HEAD') | Out-Null
    Run 'Sync-Dossier.ps1' @('-Apply') | Out-Null
    $f = ((Read-Json $statusFile).products | Where-Object { $_.key -eq 'core' }).forks[0]
    Check 'merging moves the base to the product head' ($f.base -eq $c4 -and $f.behind -eq 0 -and @($f.changed).Count -eq 0) ($f | ConvertTo-Json)

    # a repo that shares no history
    $wNew = "$ws\clients\widgetco\w-new"
    RunExe 'git' @('init', '-q', $wNew) $tmp | Out-Null
    Commit $wNew 'own.txt' | Out-Null
    $widgetC = With $widget @{ basedOn = @('base', 'core'); repos = @($fork, @{ remote = $src2; dir = 'w-new'; from = @{ product = 'core'; repo = 'app' } }) }
    Write-Registry @($acmeB, $widgetC, $betaC, $gamma) -Products @($prod, $core)
    Run 'Sync-Dossier.ps1' @('-Apply') | Out-Null
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor warns about a fork with no shared commit' ($d.Out -match "WARN\s+\[widgetco\] repo 'w-new' is registered as a fork of 'app', but shares no commit") $d.Out
    $g = Guard $wApp $wHome
    Check 'guard: the note says a fork shares no commit' ($g.Out -match 'w-new is registered as a fork of core/app, but shares no commit') $g.Out

    # a fork must come from a repo clients read in full
    $coreSub = With $core @{ clientRead = @('app/sub') }
    Write-Registry @($acmeB, $widgetC, $betaC, $gamma) -Products @($prod, $coreSub)
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor fails a fork of a repo not readable in full' ($d.Code -eq 1 -and $d.Out -match "FAIL\s+\[widgetco\] repo 'w-app' is a fork of 'core/app', but clientRead doesn't cover all of that repo") $d.Out
    $r = Run 'Sync-Dossier.ps1'
    Check 'status for such a fork says the repo isn''t readable' ($r.Out -match 'plan\s+write .*widgetco\\dossier\.products\.json')

    # an enterprise client's repos are never read from inside a session
    $acmeC = With $acmeB @{ basedOn = @('base', 'core') }
    Write-Registry @($acmeC, $widgetC, $betaC, $gamma) -Products @($prod, $core)
    $env:CLAUDECODE = '1'
    $r = Run 'Sync-Dossier.ps1'
    Remove-Item Env:\CLAUDECODE
    Check 'sync skips an enterprise client''s status inside a session' ($r.Out -match "skip\s+product status for 'acme'") $r.Out

    # dropping basedOn removes the status file and the skill
    Write-Registry @($acmeB, $widget, $betaC, $gamma) -Products @($prod, $core)
    Run 'Sync-Dossier.ps1' @('-Apply') | Out-Null
    Check 'no basedOn: status file and skill removed' (-not (Test-Path $statusFile) -and -not (Test-Path "$wHome\skills\dossier-product"))

    # --- agents
    $roster = "$tmp\.dossier\agents"
    New-Item -ItemType Directory -Path $roster -Force | Out-Null
    function Agent([string] $Name, [string] $Body = 'Voice: dry.', [string] $Extra = "memory: user`n") {
        [IO.File]::WriteAllText("$roster\$Name.md", "---`nname: $Name`ndescription: test agent $Name`n$($Extra)color: blue`n---`n`n$Body`n")
    }
    foreach ($n in 'chief', 'bob', 'rae', 'hal') { Agent $n }
    $team = [ordered]@{ source = '~/.dossier/agents'; roles = [ordered]@{ lead = 'chief'; builder = 'bob'; reviewer = 'rae'; hr = 'hal' } }
    $clients = @($acmeB, $widget, $betaC, $gamma)
    $badAgents = @(
        @{ n = 'an unknown role'; a = [ordered]@{ source = '~/.dossier/agents'; roles = @{ janitor = 'bob' } }; c = $clients },
        @{ n = 'one agent in two roles'; a = [ordered]@{ source = '~/.dossier/agents'; roles = [ordered]@{ builder = 'bob'; reviewer = 'bob' } }; c = $clients },
        @{ n = 'an agent name with a colon'; a = [ordered]@{ source = '~/.dossier/agents'; roles = @{ builder = 'x:y' } }; c = $clients },
        @{ n = 'agents with no source'; a = [ordered]@{ roles = @{ builder = 'bob' } }; c = $clients },
        @{ n = 'hr in a client home'; a = $team; c = @(With $widget @{ agentRoles = @('builder', 'hr') }) },
        @{ n = 'agentNames on a no-seat client'; a = $team; c = @(With $widget @{ agentNames = @{ lead = 'shep' } }) },
        @{ n = 'agentNames on a product'; a = $team; c = $clients; p = @($prod, (With $core @{ agentNames = @{ lead = 'shep' } })) },
        @{ n = 'agentNames with hr'; a = $team; c = @(With $acmeB @{ agentNames = @{ hr = 'shep' } }) },
        @{ n = 'agentNames with an unknown role'; a = $team; c = @(With $acmeB @{ agentNames = @{ janitor = 'shep' } }) },
        @{ n = 'agentNames with a bad name'; a = $team; c = @(With $acmeB @{ agentNames = @{ lead = 'x:y' } }) },
        @{ n = 'agentNames that aren''t a map'; a = $team; c = @(With $acmeB @{ agentNames = @('shep') }) },
        @{ n = 'agentNames using the roster''s agent for another role'; a = $team; c = @(With $acmeB @{ agentNames = @{ lead = 'bob' } }) },
        @{ n = 'agentNames with one agent in two roles'; a = $team; c = @(With $acmeB @{ agentNames = [ordered]@{ lead = 'shep'; ops = 'shep' } }) }
    )
    foreach ($b in $badAgents) {
        Write-Registry $b.c -Products ($b.p ?? @($prod, $core)) -Agents $b.a
        $threw = $false; try { Read-DsrRegistry | Out-Null } catch { $threw = $true }
        Check "registry rejects $($b.n)" $threw
    }
    Write-Registry $clients -Products @($prod, $core) -Agents $team
    $raw = Get-Content -Raw $env:DOSSIER_CONFIG | ConvertFrom-Json -AsHashtable; $raw.firm.agentNames = @{ lead = 'shep' }
    [IO.File]::WriteAllText($env:DOSSIER_CONFIG, ($raw | ConvertTo-Json -Depth 8))
    $threw = $false; try { Read-DsrRegistry | Out-Null } catch { $threw = $true }
    Check 'registry rejects agentNames on the firm' $threw
    Write-Registry @(With $acmeB @{ agentNames = @{ builder = 'bob' } }) -Products @($prod, $core) -Agents $team
    $threw = $false; try { Read-DsrRegistry | Out-Null } catch { $threw = $true }
    Check 'registry accepts agentNames naming the roster''s own agent for that role' (-not $threw)

    # homes that already hold agent files: Dossier's own copies are replaced by the link, anything else stops it
    $coreHome = "$tmp\.claude-homes\core"; $gHome = "$tmp\.claude-homes\gamma"
    New-Item -ItemType Directory -Path "$coreHome\agents", "$gHome\agents" -Force | Out-Null
    [IO.File]::WriteAllText("$coreHome\agents\old.md", "---`nname: old`n---`n`n$($script:DsrAgentMarker)`n")
    [IO.File]::WriteAllText("$gHome\agents\own.md", "---`nname: own`ndescription: hand-made`n---`n")

    $betaOne = With $betaC @{ agentRoles = @('builder') }
    $betaLead = With $betaC @{ agentRoles = @('lead', 'builder') }
    Write-Registry @($acmeB, $widget, $betaLead, $gamma) -Products @($prod, $core) -Agents $team
    $r = Run 'Sync-Dossier.ps1' @('-Apply')
    Check 'sync with agents exits 0' ($r.Code -eq 0) "$($r.Out) $($r.Err)"
    $fHome = "$tmp\.claude"
    Check 'firm home gets every role' ((Test-Path "$fHome\agents\chief.md") -and (Test-Path "$fHome\agents\bob.md") -and (Test-Path "$fHome\agents\rae.md") -and (Test-Path "$fHome\agents\hal.md"))
    $rae = Get-Content -Raw "$fHome\agents\rae.md"
    Check 'installed agent keeps the roster text, then its role contract and common rules' ($rae -match '(?s)\A---\nname: rae.*Voice: dry\..*managed by dossier: role contract.*## Role: reviewer.*Memory, in three layers')
    Check 'firm main session runs as the lead' ((Read-Json "$fHome\settings.json").agent -eq 'chief')
    $wl = Get-Item -LiteralPath "$wHome\agents" -Force
    Check 'a no-seat client home links to the firm home''s agents' ($wl.LinkType -and (Test-DsrSamePath ([string]@($wl.Target)[0]) "$fHome\agents") -and (Test-Path "$wHome\agents\rae.md"))
    Check 'a product home links too' ((Get-Item -LiteralPath "$coreHome\agents" -Force).LinkType -and (Test-Path "$coreHome\agents\rae.md"))
    Check 'Dossier''s old copies are replaced by the link' (-not (Test-Path "$fHome\agents\old.md"))
    Check 'a home with its own agent files isn''t linked' (-not (Get-Item -LiteralPath "$gHome\agents" -Force).LinkType -and (Test-Path "$gHome\agents\own.md") -and $r.Out -match "warn\s+.*gamma\\agents has agents of its own \(own\.md\)") $r.Out
    Check 'client main session is left alone' (-not (Read-Json "$wHome\settings.json").Contains('agent'))
    Check 'a linked home can opt into the lead' ((Read-Json "$tmp\.claude-homes\beta\settings.json").agent -eq 'chief')
    $aHome = "$tmp\.claude-homes\acme"
    Check 'an enterprise home gets its own copies, without lead or hr' (-not (Get-Item -LiteralPath "$aHome\agents" -Force).LinkType -and (Test-Path "$aHome\agents\bob.md") -and -not (Test-Path "$aHome\agents\hal.md") -and -not (Test-Path "$aHome\agents\chief.md"))
    $r = Run 'Sync-Dossier.ps1' @('-Apply')
    Check 'sync with agents is idempotent' ($r.Out -match 'In sync\.') $r.Out
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor lists the firm home''s agents' ($d.Out -match 'ok\s+\[firm\] agents: chief \(lead\), bob \(builder\), rae \(reviewer\), hal \(hr\)') $d.Out
    Check 'doctor accepts the agents link' ($d.Out -match 'ok\s+\[widgetco\] agents: shared with the firm home' -and $d.Out -notmatch '\[widgetco\].*links into another home') $d.Out
    Check 'doctor flags a home that should be linked' ($d.Out -match "WARN\s+\[gamma\] agents folder isn't linked") $d.Out
    Remove-Item -Recurse "$gHome\agents"

    # editing the roster: linked homes see it at once, enterprise copies wait for Sync
    Agent 'rae' 'Voice: very dry.'
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor finds enterprise copies out of date' ($d.Out -match 'WARN\s+\[acme\] agents out of date: bob, rae' -or $d.Out -match 'WARN\s+\[acme\] agents out of date: rae') $d.Out
    Run 'Sync-Dossier.ps1' @('-Apply') | Out-Null
    Check 'sync rolls an edit out to the firm, linked and enterprise homes' ((Get-Content -Raw "$wHome\agents\rae.md") -match 'very dry' -and (Get-Content -Raw "$aHome\agents\rae.md") -match 'very dry')
    Agent 'bob' 'Voice: none.' ''
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor warns about an agent with no memory' ($d.Out -match "WARN\s+\[firm\] agent 'bob' has no 'memory: user'") $d.Out
    Agent 'bob'
    [IO.File]::WriteAllText("$roster\rae.md", "---`nname: ray`ndescription: x`n---`nbody`n")
    $r = Run 'Sync-Dossier.ps1'
    Check 'sync skips an agent whose file names another agent' ($r.Out -match "warn\s+.*rae\.md says name: 'ray'") $r.Out
    Agent 'rae'

    # dropping roles removes only Dossier's own files and settings
    [IO.File]::WriteAllText("$fHome\agents\mine.md", "---`nname: mine`ndescription: hand-made`n---`n")
    $s = Read-Json "$wHome\settings.json"; $s.agent = 'mine'; [IO.File]::WriteAllText("$wHome\settings.json", ($s | ConvertTo-Json -Depth 32))
    $team2 = [ordered]@{ source = '~/.dossier/agents'; roles = [ordered]@{ builder = 'bob'; hr = 'hal' } }
    Write-Registry @($acmeB, $widget, $betaOne, $gamma) -Products @($prod, $core) -Agents $team2
    Run 'Sync-Dossier.ps1' @('-Apply') | Out-Null
    Check 'a dropped role''s agent is removed everywhere' (-not (Test-Path "$fHome\agents\rae.md") -and -not (Test-Path "$wHome\agents\rae.md") -and -not (Test-Path "$aHome\agents\rae.md"))
    Check 'a hand-made agent file is left alone, and linked homes see it' ((Test-Path "$fHome\agents\mine.md") -and (Test-Path "$wHome\agents\mine.md"))
    Check 'dropping the lead clears the setting Sync made' (-not (Read-Json "$fHome\settings.json").Contains('agent') -and -not (Read-Json "$tmp\.claude-homes\beta\settings.json").Contains('agent'))
    Check 'a main agent the user set is left alone' ((Read-Json "$wHome\settings.json").agent -eq 'mine')

    # an enterprise entry's own lead: its home gets that agent, the firm keeps the roster's
    Agent 'shep'; Agent 'otto'
    $acmeOwn = With $acmeB @{ agentRoles = @('lead', 'builder', 'ops'); agentNames = [ordered]@{ lead = 'shep'; ops = 'otto' } }
    Write-Registry @($acmeOwn, $widget, $betaOne, $gamma) -Products @($prod, $core) -Agents $team
    $r = Run 'Sync-Dossier.ps1' @('-Apply')
    Check 'sync with agentNames exits 0' ($r.Code -eq 0) "$($r.Out) $($r.Err)"
    Check 'an enterprise home gets its named lead, not the roster''s' ((Test-Path "$aHome\agents\shep.md") -and -not (Test-Path "$aHome\agents\chief.md") -and (Test-Path "$aHome\agents\bob.md"))
    Check 'the named lead is installed with the lead contract' ((Get-Content -Raw "$aHome\agents\shep.md") -match '(?s)\A---\nname: shep.*## Role: lead')
    Check 'a role the roster leaves empty can be filled by agentNames' (Test-Path "$aHome\agents\otto.md")
    Check 'the enterprise main session runs as its named lead' ((Read-Json "$aHome\settings.json").agent -eq 'shep' -and (Read-Json "$aHome\dossier.managed.json").agent -eq 'shep')
    Check 'the firm keeps the roster''s lead' ((Read-Json "$fHome\settings.json").agent -eq 'chief' -and (Test-Path "$fHome\agents\chief.md") -and -not (Test-Path "$fHome\agents\shep.md") -and -not (Test-Path "$fHome\agents\otto.md"))
    $r = Run 'Sync-Dossier.ps1' @('-Apply')
    Check 'sync with agentNames is idempotent' ($r.Out -match 'In sync\.') $r.Out
    $d = Run 'Test-Dossier.ps1'
    Check 'doctor lists the enterprise home''s own agents' ($d.Out -match 'ok\s+\[acme\] agents: shep \(lead\), bob \(builder\), otto \(ops\)' -and $d.Out -notmatch '\[acme\] main session should run') $d.Out
    Write-Registry @((With $acmeB @{ agentNames = [ordered]@{ lead = 'shep'; ops = 'otto' } }), $widget, $betaOne, $gamma) -Products @($prod, $core) -Agents $team
    Run 'Sync-Dossier.ps1' @('-Apply') | Out-Null
    Check 'agentNames alone doesn''t bring the lead' (-not (Test-Path "$aHome\agents\shep.md") -and -not (Read-Json "$aHome\settings.json").Contains('agent') -and (Test-Path "$aHome\agents\otto.md") -and (Test-Path "$aHome\agents\rae.md"))

    # no agents in the registry: Dossier's links go
    Write-Registry @($acmeB, $widget, $betaOne, $gamma) -Products @($prod, $core)
    Run 'Sync-Dossier.ps1' @('-Apply') | Out-Null
    Check 'removing the agents section removes the links' (-not (Test-Path "$wHome\agents") -and (Test-Path "$fHome\agents\mine.md"))
} finally {
    if ($substDrive) { subst "${substDrive}:" /d 2>$null | Out-Null }
    foreach ($v in $saveVars) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
    Get-ChildItem -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.LinkType -and $_.PSIsContainer } | ForEach-Object { [IO.Directory]::Delete($_.FullName) }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
