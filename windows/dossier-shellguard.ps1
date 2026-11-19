# dossier-shellguard.ps1 - PreToolUse hook for Bash and PowerShell: holds shell commands to the
# home's own Read/Edit deny rules. Sync-Dossier.ps1 wires it into every home's settings.json.
#
# Claude Code's sandbox would enforce those rules on shell commands at the OS level, but it doesn't
# run on native Windows, and without it deny rules only cover the file tools and a few recognized
# Bash commands (cat, head, tail, sed, tee). This is a tripwire for honest mistakes, not a
# boundary: it reads the command text, so a path built at run time, a script that opens files
# itself, or a link into a denied folder gets past it. It denies a command that
#   - names a denied path, absolute or relative to the session's folder, in Windows, Git Bash or
#     WSL form, through ~, $HOME, $env:USERPROFILE or %USERPROFILE%
#   - has a wildcard whose fixed part is a folder holding a denied path
#   - searches or copies recursively from a folder holding a denied path
# Its own failures let the command through, with a note.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Dossier.Common.ps1"

function Out-Deny([string] $Reason) {
    $o = [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $Reason } }
    [Console]::Out.Write(($o | ConvertTo-Json -Depth 5 -Compress))
    exit 0
}

function ConvertFrom-RulePath([string] $Rule) {
    # Read(//c/x/y/**) -> C:\x\y ; Read(~/x) -> <home>\x ; anything else (project-relative, inner wildcards) -> $null
    $m = [regex]::Match($Rule, '^\s*(Read|Edit)\((.*)\)\s*$')
    if (-not $m.Success) { return $null }
    $p = $m.Groups[2].Value -replace '/\*\*?$', ''
    if ($p -match '[*?\[]') { return $null }
    if ($p -match '^//([A-Za-z])(/.*)?$') { return Resolve-DsrPath ($Matches[1].ToUpper() + ':' + $(if ($Matches[2]) { $Matches[2] } else { '/' })) }
    if ($p -eq '~' -or $p.StartsWith('~/')) { return Resolve-DsrPath $p }
    return $null
}

try {
    $in = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $command = [string]$in.tool_input.command
    if (-not $command) { exit 0 }
    $cwd = if ($in.cwd) { [string]$in.cwd } else { (Get-Location).ProviderPath }

    $homePath = if ($env:CLAUDE_CONFIG_DIR) { Resolve-DsrPath $env:CLAUDE_CONFIG_DIR } else { Resolve-DsrPath '~/.claude' }
    $settingsFile = Join-Path $homePath 'settings.json'
    if (-not (Test-Path -LiteralPath $settingsFile)) { exit 0 }
    $s = [IO.File]::ReadAllText($settingsFile) | ConvertFrom-Json
    $rules = @(); if ($s -and $s.permissions -and $s.permissions.deny) { $rules = @($s.permissions.deny) }
    $denied = @($rules | ForEach-Object { ConvertFrom-RulePath ([string]$_) } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $denied.Count) { exit 0 }

    $userHome = Get-DsrUserHome
    $text = $command
    foreach ($v in '${env:USERPROFILE}', '$env:USERPROFILE', '${HOME}', '$HOME', '%USERPROFILE%') {
        $text = [regex]::Replace($text, [regex]::Escape($v) + '(?![A-Za-z0-9_])', $userHome.Replace('$', '$$'), 'IgnoreCase')
    }
    # One spelling for every path form: backslashes, single separators, drive letters.
    $text = $text.Replace('/', '\') -replace '\\{2,}', '\'
    $text = [regex]::Replace($text, '(?<![A-Za-z0-9:._~-])\\(?:mnt\\)?([A-Za-z])(?=\\|$|[\s"''`;|&)])', '$1:')

    function Get-Hit([string] $Path) { foreach ($d in $denied) { if (Test-DsrUnder $Path $d) { return $d } }; return $null }
    function Get-Holder([string] $Path) { foreach ($d in $denied) { if ((Test-DsrUnder $d $Path) -and -not (Test-DsrUnder $Path $d)) { return $d } }; return $null }
    $why = 'This home''s deny rules keep it out of {0}. Don''t work around that; tell the user, who can relaunch with cc in the folder that owns it.'

    foreach ($d in $denied) {
        if ($text -match ('(?i)' + [regex]::Escape($d) + '(?=$|[\\\s"''`;|&)>,*?\]])')) { Out-Deny ("dossier-shellguard: the command names $d. " + ($why -f $d)) }
    }

    if (Test-Path -LiteralPath $cwd) { Set-Location -LiteralPath $cwd }
    $existing = 0; $holders = @()
    foreach ($t in ($text -split '[\s"''`;|&()<>,=]+')) {
        if (-not $t -or $t.StartsWith('-') -or $t -match '^[A-Za-z][A-Za-z0-9+.-]+:') { continue }
        $wild = $t.IndexOfAny([char[]]'*?[')
        try {
            if ($wild -ge 0) {
                $fixed = $t.Substring(0, $wild); $cut = $fixed.LastIndexOf('\')
                $fixed = if ($cut -ge 0) { $fixed.Substring(0, $cut + 1) } else { '.' }
                $p = Resolve-DsrPath $fixed
                $h = (Get-Hit $p) ?? (Get-Holder $p)
                if ($h) { Out-Deny ("dossier-shellguard: the wildcard in '$t' can reach $h. " + ($why -f $h)) }
                continue
            }
            $p = Resolve-DsrPath $t
        } catch { continue }
        if (-not $p) { continue }
        $h = Get-Hit $p
        if ($h) { Out-Deny ("dossier-shellguard: '$t' is inside $h. " + ($why -f $h)) }
        if (Test-Path -LiteralPath $p) { $existing++; $holders += $p }
    }

    $recursive = '(?i)(^|[\s;|&(])((rg|ag|find|tree|du|robocopy|xcopy|tar|zip|7z|Compress-Archive)(?=\s|$)|Copy-Item\b[^;|&]*-r|cp\s+-[a-zA-Z]*[rR]|grep\s+[^;|&]*-[a-zA-Z]*[rR]|ls\s+[^;|&]*-[a-zA-Z]*R|Get-ChildItem\b[^;|&]*-r|gci\b[^;|&]*-r|dir\b[^;|&]*(-r|\\s\b)|Select-String\b[^;|&]*-r)'
    if ($text -match $recursive) {
        if ($existing -eq 0) { $holders += (Resolve-DsrPath $cwd) }
        foreach ($p in $holders) {
            $h = Get-Holder $p
            if ($h) { Out-Deny ("dossier-shellguard: a recursive command from $p would reach $h. Point it at a narrower folder. " + ($why -f $h)) }
        }
    }
} catch {
    $o = @{ systemMessage = "[dossier-shellguard] could not check this command ($($_.Exception.Message)); it ran unchecked." }
    [Console]::Out.Write(($o | ConvertTo-Json -Compress))
}
exit 0
