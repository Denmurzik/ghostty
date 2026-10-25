# typing-unicode: VK_PACKET input (any character, no layout), including a
# surrogate pair (an emoji sent as two UTF-16 units), arrives as the right
# UTF-8 bytes.
#
# The receiver is a small PowerShell script that dumps the raw bytes it reads
# from the console: Git Bash (MSYS) mangles astral characters on its own
# console input (it loses the high surrogate), which would hide what
# Ghostty actually sent.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'typing-unicode' {
    $reader = Join-Path $script:Sbx.Root 'read-bytes.ps1'
    Set-Content -LiteralPath $reader -Encoding ASCII -Value @'
[Console]::InputEncoding = [Text.Encoding]::UTF8
$in = [Console]::OpenStandardInput()
$buf = New-Object byte[] 256
$n = $in.Read($buf, 0, 256)
$hex = ($buf[0..($n - 1)] | ForEach-Object { $_.ToString('x2') }) -join ' '
[IO.File]::WriteAllText((Join-Path $env:TEMP 'raw.txt'), $hex)
Start-Sleep -Seconds 2
'@
    # `direct:` splits on spaces: forward slashes, no quotes.
    $arg = $reader.Replace('\', '/')
    $cfg = $script:BaseConfig + "`ncommand = direct:powershell.exe -NoProfile -ExecutionPolicy Bypass -File $arg`n"
    $g = Start-E2eGhostty -ConfigText $cfg
    if (-not (Wait-ChildNamed $g @('powershell.exe') 15)) { throw 'the reader process did not start' }
    Set-WindowLayout $g.Hwnd '00000409'

    # U+1F600 (surrogate pair), Zhe, zhe, a CJK character; then Enter.
    $text = ConvertFrom-CodePoints 0x1F600, 0x416, 0x436, 0x4E2D
    Invoke-SendInput -Hwnd $g.Hwnd -Text $text
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'enter'

    $file = Join-Path $g.Sandbox.Tmp 'raw.txt'
    if (-not (Wait-File $file 20)) { throw 'the reader never reported the bytes it received' }
    $got = (Get-Content -LiteralPath $file -Raw).Trim()
    $want = (([Text.Encoding]::UTF8.GetBytes($text) | ForEach-Object { $_.ToString('x2') }) -join ' ') + ' 0d 0a'
    if ($got -ne $want) { throw "the child received bytes '$got', expected '$want'" }
    Write-E2eInfo "VK_PACKET ok, bytes: $got"
}
