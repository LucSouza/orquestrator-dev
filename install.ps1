# Installs the /orchestrator skill for Claude Code (user level: works in every project on this PC)
# and adds the safety hook (guard.ps1) to %USERPROFILE%\.claude\settings.json.
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false

$src = Join-Path $PSScriptRoot 'orchestrator'
$claudeDir = Join-Path $env:USERPROFILE '.claude'
$dst = Join-Path $claudeDir 'skills\orchestrator'
New-Item -ItemType Directory -Force -Path $dst | Out-Null

# Keep the user's config.json if it already exists.
$keepCfg = $null
$cfgPath = Join-Path $dst 'config.json'
if (Test-Path $cfgPath) { $keepCfg = [System.IO.File]::ReadAllText($cfgPath) }
Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
if ($keepCfg) {
    $old = $keepCfg | ConvertFrom-Json
    $new = [System.IO.File]::ReadAllText((Join-Path $src 'config.json')) | ConvertFrom-Json
    $added = @()
    foreach ($p in $new.PSObject.Properties) {
        if (-not $old.PSObject.Properties[$p.Name]) { $old | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value; $added += $p.Name }
    }
    # v1.2: DeepSeek becomes an automatic reserve (only runs when Gemini/GPT-OSS fail).
    $ds = $null
    if ($old.vendors -and $old.vendors.PSObject.Properties['deepseek']) { $ds = $old.vendors.deepseek }
    if ($ds -and -not $ds.PSObject.Properties['fallback']) {
        $ds | Add-Member -NotePropertyName fallback -NotePropertyValue $true
        $ds.enabled = $true
        $added += 'deepseek como reserva automatica'
    }
    # v1.3: Jev through Vercel AI Gateway by default.
    if ($old.jev -and -not $old.jev.PSObject.Properties['provider']) {
        $old.jev | Add-Member -NotePropertyName provider -NotePropertyValue 'vercel'
        if ("$($old.jev.model)" -eq 'jev-latest') { $old.jev.model = 'typesafe-ai/jev' }
        $added += 'jev via Vercel AI Gateway'
    }
    [System.IO.File]::WriteAllText($cfgPath, ($old | ConvertTo-Json -Depth 12), $utf8)
    Write-Host "config.json existente preservado." -NoNewline
    if ($added) { Write-Host " Secoes novas adicionadas: $($added -join ', ')" } else { Write-Host "" }
}
Get-ChildItem -LiteralPath $dst -Recurse -File | Unblock-File
Write-Host "Skill instalada em $dst" -ForegroundColor Green

# --- Hook ---
$settingsPath = Join-Path $claudeDir 'settings.json'
$s = $null
if (Test-Path $settingsPath) {
    $rawSettings = [System.IO.File]::ReadAllText($settingsPath)
    Copy-Item $settingsPath ($settingsPath + '.bak-' + (Get-Date -Format 'yyyyMMddHHmmss'))
    if ($rawSettings.Trim()) { $s = $rawSettings | ConvertFrom-Json }
}
if (-not $s) { $s = New-Object PSObject }

$guard = (Join-Path $dst 'scripts\guard.ps1') -replace '\\', '/'
$hookCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$guard`""
$entry = [pscustomobject]@{
    matcher = 'Bash|PowerShell'
    hooks   = @([pscustomobject]@{ type = 'command'; command = $hookCmd })
}

if (-not $s.PSObject.Properties['hooks']) { $s | Add-Member -NotePropertyName hooks -NotePropertyValue (New-Object PSObject) }
if (-not $s.hooks.PSObject.Properties['PreToolUse']) { $s.hooks | Add-Member -NotePropertyName PreToolUse -NotePropertyValue @() }

$already = @($s.hooks.PreToolUse) | Where-Object {
    $_ -and (@($_.hooks) | Where-Object { "$($_.command)" -match 'orchestrator.*guard\.ps1' })
}
if ($already) {
    Write-Host "Hook ja estava instalado." -ForegroundColor Yellow
} else {
    $s.hooks.PreToolUse = @(@($s.hooks.PreToolUse) | Where-Object { $_ }) + $entry
    [System.IO.File]::WriteAllText($settingsPath, ($s | ConvertTo-Json -Depth 32), $utf8)
    Write-Host "Hook de seguranca adicionado em $settingsPath (backup criado)." -ForegroundColor Green
}

Write-Host ""
Write-Host "Proximos passos:" -ForegroundColor Cyan
Write-Host "  1. Rode: agy models   e copie os ids do Gemini e do GPT-OSS para:"
Write-Host "     $cfgPath"
Write-Host "  2. Teste: powershell -NoProfile -ExecutionPolicy Bypass -File `"$dst\scripts\test-vendors.ps1`""
Write-Host "  3. Em cada repo que pode usar fornecedores externos, crie .orchestrator.json (veja o LEIA-ME)."
Write-Host "  4. Abra o Claude Code no repo e use: /orchestrator <sua tarefa>"
