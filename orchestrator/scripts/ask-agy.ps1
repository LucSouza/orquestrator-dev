# Sends one prompt file to the Antigravity CLI (agy) and writes the text answer.
# agy runs in an EMPTY temp folder that only holds input.md, so it cannot see or touch your repo.
# ASCII only on purpose (Windows PowerShell 5.1 reads BOM-less scripts as ANSI).
param(
    [Parameter(Mandatory = $true)][string]$InputFile,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [Parameter(Mandatory = $true)][string]$Model,
    [int]$TimeoutSec = 300,
    [string]$ExtraArgs = "--output-format text"
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false

function Write-Out([string]$text) {
    [System.IO.File]::WriteAllText($OutFile, $text, $utf8)
}

$cmd = Get-Command agy -ErrorAction SilentlyContinue
if (-not $cmd) {
    $guess = Join-Path $env:USERPROFILE '.local\bin\agy.exe'
    if (Test-Path $guess) { $agy = $guess } else { Write-Out "ERRO: agy nao encontrado no PATH."; exit 1 }
} else { $agy = $cmd.Source }

$work = Join-Path $env:TEMP ("orq-agy-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    Copy-Item -LiteralPath $InputFile -Destination (Join-Path $work 'input.md')
    $stdin  = Join-Path $work '_stdin.txt'
    $stdout = Join-Path $work '_stdout.txt'
    $stderr = Join-Path $work '_stderr.txt'
    [System.IO.File]::WriteAllText($stdin, '', $utf8)

    $instr = 'Leia o arquivo input.md nesta pasta. Ele contem sua tarefa completa e o contexto. ' +
             'Siga a tarefa e responda apenas com texto em markdown, em portugues. ' +
             'Nao crie, edite nem apague arquivos e nao execute comandos.'
    $argLine = "-p `"$instr`" --model $Model $ExtraArgs"

    $p = Start-Process -FilePath $agy -ArgumentList $argLine -WorkingDirectory $work `
        -RedirectStandardInput $stdin -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
        -NoNewWindow -PassThru
    $null = $p.Handle  # needed so ExitCode is available on PowerShell 5.1

    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        & taskkill /PID $p.Id /T /F 2>$null | Out-Null
        Write-Out "ERRO: agy ($Model) passou de $TimeoutSec s e foi encerrado."
        exit 1
    }
    $p.WaitForExit()

    $out = ''
    if (Test-Path $stdout) { $out = [System.IO.File]::ReadAllText($stdout, [System.Text.Encoding]::UTF8) }
    $err = ''
    if (Test-Path $stderr) { $err = [System.IO.File]::ReadAllText($stderr, [System.Text.Encoding]::UTF8) }

    if ($p.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($out)) {
        Write-Out ("ERRO: agy ($Model) saiu com codigo $($p.ExitCode).`n`n" + $err + "`n" + $out)
        exit 1
    }
    Write-Out $out
    exit 0
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
