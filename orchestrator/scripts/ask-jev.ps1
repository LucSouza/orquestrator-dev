# Jev decisions used by the /orchestrator skill. Jev may only ADD caution, never remove it.
#
#   -Mode risk     -InputFile brief.md   -Claimed normal|sensivel
#        Second opinion on the task's risk class. Can raise normal -> sensivel, never lower.
#   -Mode same     -InputFile pairs.json
#        pairs.json = [ { "id": "p1", "a": "texto do passo", "b": "texto do outro passo" }, ... ]
#        Says which pairs are the same change worded differently. Advisory only.
#   -Mode severity -InputFile findings.md [-Context diff.patch] -OutFile findings-jev.md
#        findings.md lines look like: - [ALTO] arquivo:linha - problema - ...
#        Raises a finding's severity when Jev is confident it is worse. Never lowers.
#   -Mode screen   -InputFile any.md
#        Same injection/danger screen that ask-all.ps1 applies automatically.
param(
    [Parameter(Mandatory = $true)][ValidateSet('risk', 'same', 'severity', 'screen')][string]$Mode,
    [Parameter(Mandatory = $true)][string]$InputFile,
    [string]$Claimed = 'normal',
    [string]$Context = '',
    [string]$OutFile = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'orq-lib.ps1')

$opt = Get-RepoOptIn
$cfg = Get-OrqConfig
if (-not ($cfg.jev -and $cfg.jev.enabled)) { Orq-Fail "Jev desativado em config.json." }
if (-not (Test-VendorAllowed $opt 'jev')) { Orq-Fail "Jev nao esta liberado em .orchestrator.json deste repo." }

$inText = Read-Utf8 $InputFile
$hit = Find-Secret $inText
if ($hit) { Orq-Fail "possivel segredo no arquivo enviado ao Jev (padrao: $hit). Remova antes." }

$C_CRIT = 'CR' + [char]0x00CD + 'TICO'
$C_MED  = 'M' + [char]0x00C9 + 'DIO'

try {
    switch ($Mode) {

        'risk' {
            $q = @{
                sensitive = @{
                    type = 'noul'
                    instructions = 'Is the software task described in `brief` security-sensitive: does it touch authentication, authorization or permissions, payments, money or balances, personal data, cryptography or signatures, secrets, database migrations or data deletion, or production infrastructure?'
                    criteria = @{ 'true' = 'Security-sensitive task'; 'false' = 'Ordinary low-risk task' }
                }
            }
            $res = Invoke-Jev $cfg @{ brief = (Limit-Text $inText) } $q
            $p = [double]$res.answers.sensitive.noul
            $claimedSens = ($Claimed -match '(?i)^sens')
            $final = if ($claimedSens -or $p -ge [double]$cfg.jev.raiseRisk) { 'sensivel' } else { 'normal' }
            $note = if (-not $claimedSens -and $final -eq 'sensivel') { ' (ELEVADO pelo Jev)' } else { '' }
            Write-Output ("JEV risco: p(sensivel)={0:N2} | Claude disse: {1} | RISCO FINAL: {2}{3}" -f $p, $Claimed, $final, $note)
        }

        'same' {
            $parsed = $inText | ConvertFrom-Json
            $pairs = @($parsed | ForEach-Object { $_ })   # PS 5.1 returns JSON arrays as one object
            if ($pairs.Count -eq 0) { Orq-Fail "pairs.json vazio." }
            $state = @{}; $q = @{}
            foreach ($pr in $pairs) {
                $id = ($pr.id -replace '[^A-Za-z0-9_]', '_')
                $state[$id] = @{ a = "$($pr.a)"; b = "$($pr.b)" }
                $q[$id] = @{
                    type = 'noul'
                    instructions = "Do ``$id.a`` and ``$id.b`` describe the same code change, just worded differently?"
                    criteria = @{ 'true' = 'Same change'; 'false' = 'Different changes' }
                }
            }
            $res = Invoke-Jev $cfg @{ pairs = $state } $q
            foreach ($id in ($q.Keys | Sort-Object)) {
                $p = [double]$res.answers.$id.noul
                $tag = if ($p -ge 0.7) { 'MESMA MUDANCA' } elseif ($p -ge 0.4) { 'talvez' } else { 'diferentes' }
                Write-Output ("{0}: p={1:N2} -> {2}" -f $id, $p, $tag)
            }
            Write-Output "JEV: consultivo. Voce decide se unifica os passos."
        }

        'severity' {
            if (-not $OutFile) { Orq-Fail "informe -OutFile para o modo severity." }
            $rank = @{ 'baixo' = 0; 'medio' = 1; 'alto' = 2; 'critico' = 3 }
            $label = @{ 'baixo' = 'BAIXO'; 'medio' = $C_MED; 'alto' = 'ALTO'; 'critico' = $C_CRIT }
            $rx = [regex]'^(?<pre>\s*[-*]?\s*`?\[)(?<sev>CR.TICO|CRITICO|ALTO|M.DIO|MEDIO|BAIXO)(?<post>\].*)$'
            $lines = $inText -split "`r?`n"
            $found = @()
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $m = $rx.Match($lines[$i])
                if ($m.Success) {
                    $s = $m.Groups['sev'].Value.ToUpper()
                    $key = if ($s -match '^CR') { 'critico' } elseif ($s -eq 'ALTO') { 'alto' } elseif ($s -match '^M') { 'medio' } else { 'baixo' }
                    $found += [pscustomobject]@{ Line = $i; Key = $key; Id = ('f' + ($found.Count + 1)); Match = $m }
                }
            }
            if ($found.Count -eq 0) { Write-Utf8 $OutFile $inText; Write-Output "JEV: nenhum achado no formato [SEVERIDADE] encontrado."; break }

            $diff = ''
            if ($Context -and (Test-Path -LiteralPath $Context)) {
                $diff = Read-Utf8 $Context
                $h2 = Find-Secret $diff
                if ($h2) { Orq-Fail "possivel segredo no diff (padrao: $h2)." }
                $diff = Limit-Text $diff 120000
            }
            $crit = @{
                critico = 'Critical: exploitable security hole, data loss or corruption, money errors, or outage'
                alto    = 'High: real bug that breaks a main flow or a likely security weakness'
                medio   = 'Medium: bug in an edge case, or missing validation or test that matters'
                baixo   = 'Low: minor issue, unlikely to cause real harm'
            }
            $changes = 0
            for ($start = 0; $start -lt $found.Count; $start += 20) {
                $batch = $found[$start..([Math]::Min($start + 19, $found.Count - 1))]
                $fs = @{}; $q = @{}
                foreach ($f in $batch) {
                    $fs[$f.Id] = $lines[$f.Line]
                    $q[$f.Id] = @{
                        type = 'choice'
                        instructions = "Assuming finding ``findings.$($f.Id)`` is real, how severe is it for the code change in ``diff``?"
                        criteria = $crit
                    }
                }
                $res = Invoke-Jev $cfg @{ diff = $diff; findings = $fs } $q
                foreach ($f in $batch) {
                    $a = $res.answers.($f.Id)
                    $choice = "$($a.choice)"
                    if (-not $rank.ContainsKey($choice)) { continue }
                    $pc = [double]$a.probabilities.$choice
                    if ($rank[$choice] -gt $rank[$f.Key] -and $pc -ge [double]$cfg.jev.raiseSeverity) {
                        $m = $f.Match
                        $lines[$f.Line] = $m.Groups['pre'].Value + $label[$choice] + $m.Groups['post'].Value +
                            (" (elevado pelo Jev de {0}, p={1:N2})" -f $label[$f.Key], $pc)
                        $changes++
                    }
                }
            }
            Write-Utf8 $OutFile ($lines -join "`r`n")
            Write-Output "JEV: $changes de $($found.Count) achados tiveram a severidade elevada. Resultado em $OutFile"
        }

        'screen' {
            $ans = (Invoke-Jev $cfg @{ stage = 'manual'; text = (Limit-Text $inText) } (Get-ScreenQuestions)).answers
            Write-Output ("JEV triagem: instrucao ao agente p={0:N2} | acao perigosa p={1:N2}" -f [double]$ans.steer.noul, [double]$ans.dangerous.noul)
        }
    }
} catch {
    Orq-Fail ("Jev falhou: " + $_.Exception.Message + " -- NADA foi filtrado/decidido. Avise o usuario.")
}
