# Shuffles the plans in InDir (<vendor>.md) into OutDir as A.md, B.md, C.md...
# Strips vendor names from the text and writes the letter->vendor mapping to MappingFile.
param(
    [Parameter(Mandatory = $true)][string]$InDir,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$MappingFile
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false

$files = Get-ChildItem -LiteralPath $InDir -File -Filter *.md | Where-Object {
    $first = Get-Content -LiteralPath $_.FullName -TotalCount 1 -Encoding UTF8
    -not ("$first".StartsWith('ERRO'))
}
if (@($files).Count -lt 2) {
    [Console]::Error.WriteLine("ORQ: menos de 2 planos validos em $InDir - debate as cegas nao faz sentido. Avise o usuario.")
    exit 1
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Get-ChildItem -LiteralPath $OutDir -File -Filter *.md | Remove-Item -Force

$names = 'Claude|Anthropic|Gemini|Google|GPT-OSS|GPT|OpenAI|ChatGPT|Codex|DeepSeek|Grok|xAI|Llama|Meta'
$shuffled = @($files) | Get-Random -Count @($files).Count
$letters = 'ABCDEFGH'
$map = [ordered]@{}
for ($i = 0; $i -lt $shuffled.Count; $i++) {
    $letter = $letters[$i].ToString()
    $txt = [System.IO.File]::ReadAllText($shuffled[$i].FullName, [System.Text.Encoding]::UTF8)
    $txt = [regex]::Replace($txt, "(?i)\b($names)\b", '[modelo]')
    [System.IO.File]::WriteAllText((Join-Path $OutDir "$letter.md"), "# Plano $letter`n`n$txt", $utf8)
    $map[$letter] = [System.IO.Path]::GetFileNameWithoutExtension($shuffled[$i].Name)
}
[System.IO.File]::WriteAllText($MappingFile, ($map | ConvertTo-Json), $utf8)
Write-Output "ORQ: $($shuffled.Count) planos anonimizados em $OutDir (mapeamento guardado, nao leia ate o Portao 1)."
