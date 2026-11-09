# Claude Code PreToolUse hook. Blocks dangerous git commands that Claude tries to run.
# Exit code 2 = block (the message goes back to Claude). Only affects Claude, never you.
$ErrorActionPreference = 'Stop'
try {
    $raw = [Console]::In.ReadToEnd()
    $in = $raw | ConvertFrom-Json
} catch { exit 0 }

$cmd = "$($in.tool_input.command)"
if (-not $cmd) { exit 0 }

function Block([string]$why) {
    [Console]::Error.WriteLine("BLOQUEADO pelo orquestrador: $why. Peca ao usuario para fazer isso manualmente.")
    exit 2
}

$branch = ''
try {
    $cwd = "$($in.cwd)"
    if ($cwd) { $branch = (& git -C $cwd rev-parse --abbrev-ref HEAD 2>$null) }
    if ($branch) { $branch = $branch.Trim() }
} catch { }
$onMain = ($branch -eq 'main' -or $branch -eq 'master')

if ($cmd -match '(?i)\bgit\b[^|;&]*\bpush\b') {
    if ($cmd -match '(?i)(--force|--force-with-lease|\s-f(\s|$)|\s\+\S)') { Block "force push" }
    if ($cmd -match '(?i)\b(main|master)\b') { Block "push para main/master" }
    if ($onMain) { Block "push estando na branch $branch" }
    if ($cmd -match '(?i)--(all|mirror|delete|tags)\b|\s:\S') { Block "push com --all/--mirror/--delete/--tags" }
}
if ($cmd -match '(?i)\bgit\b[^|;&]*\bmerge(?![-\w])')        { Block "git merge" }
if ($cmd -match '(?i)\bgh\s+pr\s+merge\b')                    { Block "merge de PR" }
if ($cmd -match '(?i)\bgit\b[^|;&]*\breset\b[^|;&]*--hard')   { Block "git reset --hard" }
if ($cmd -match '(?i)\bgit\b[^|;&]*\bclean\b[^|;&]*\s-\w*f')  { Block "git clean -f" }
if ($cmd -cmatch '\bgit\b[^|;&]*\bbranch\b[^|;&]*\s-D\b')     { Block "apagar branch com -D" }
if ($cmd -match '(?i)\bgh\s+release\s+create\b')             { Block "publicar release" }
if ($cmd -match '(?i)\bgit\b[^|;&]*\bcommit\b' -and $onMain)  { Block "commit direto na $branch (use a branch orq/...)" }
exit 0
