# Shared helpers of the Kitty clipboard scenarios (kitty-clipboard-write,
# kitty-clipboard-read, kitty-paste-event). Dot-source it after _common.ps1.
# A native vtreader (FakeExe) sends the query and prints the hex of what the
# terminal answers; the reply is read back from the screen. A native program
# runs on the bundled console under `windows-conpty = auto`, which passes
# OSC 5522 (the inbox console does not reliably deliver the replies). Keep this
# file ASCII only (Windows PowerShell 5.1 reads a BOM-less script as ANSI).

Set-StrictMode -Version Latest

Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\FakeExe.psm1') -Force

if (-not ('GhosttyKitty.Tool' -as [type])) {
    Add-Type -Namespace GhosttyKitty -Name Tool -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern uint RegisterClipboardFormatW(string name);

static void Put(System.IO.Stream f, string s) {
    byte[] b = System.Text.Encoding.ASCII.GetBytes(s);
    f.Write(b, 0, b.Length);
}

// A committed write transaction: type=write, wdata chunks per MIME (the chunk
// is raw bytes before base64), then the empty wdata that commits it.
public static void WriteQuery(string path, string[] mimes, byte[][] datas, int chunk) {
    using (System.IO.FileStream f = new System.IO.FileStream(path, System.IO.FileMode.Create)) {
        Put(f, "\u001b]5522;type=write\u001b\\");
        for (int m = 0; m < mimes.Length; m++) {
            string mb = Convert.ToBase64String(System.Text.Encoding.ASCII.GetBytes(mimes[m]));
            byte[] d = datas[m];
            for (int i = 0; i < d.Length; i += chunk) {
                int n = Math.Min(chunk, d.Length - i);
                Put(f, "\u001b]5522;type=wdata:mime=" + mb + ";" + Convert.ToBase64String(d, i, n) + "\u001b\\");
            }
        }
        Put(f, "\u001b]5522;type=wdata\u001b\\");
    }
}

// A read request: the MIME types are one space separated base64 payload.
public static void ReadQuery(string path, string mimes) {
    using (System.IO.FileStream f = new System.IO.FileStream(path, System.IO.FileMode.Create)) {
        Put(f, "\u001b]5522;type=read;" + Convert.ToBase64String(System.Text.Encoding.ASCII.GetBytes(mimes)) + "\u001b\\");
    }
}

// A bottom-up 24 bpp BI_RGB DIB (header and pixels) with a pattern that
// does not compress to nothing; solid when `pattern` is false.
public static byte[] Dib24(int w, int h, byte r, byte g, byte b, bool pattern) {
    int stride = (w * 3 + 3) & ~3;
    byte[] d = new byte[40 + stride * h];
    BitConverter.GetBytes(40).CopyTo(d, 0);
    BitConverter.GetBytes(w).CopyTo(d, 4);
    BitConverter.GetBytes(h).CopyTo(d, 8);
    BitConverter.GetBytes((short)1).CopyTo(d, 12);
    BitConverter.GetBytes((short)24).CopyTo(d, 14);
    BitConverter.GetBytes(stride * h).CopyTo(d, 20);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            int o = 40 + y * stride + x * 3;
            if (pattern) {
                d[o] = (byte)(b ^ (x >> 3)); d[o + 1] = (byte)(g ^ (y >> 3)); d[o + 2] = (byte)(r ^ ((x + y) >> 4));
            } else { d[o] = b; d[o + 1] = g; d[o + 2] = r; }
        }
    }
    return d;
}

public static byte[] Fill(int n, byte v) {
    byte[] d = new byte[n];
    for (int i = 0; i < n; i++) d[i] = v;
    return d;
}
'@
}

function ConvertTo-HexString([byte[]]$Bytes) { ($Bytes | ForEach-Object { $_.ToString('x2') }) -join '' }

function ConvertFrom-HexString([string]$Hex) {
    $b = New-Object byte[] ([int]($Hex.Length / 2))
    for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [Convert]::ToByte($Hex.Substring(2 * $i, 2), 16) }
    , $b
}

# ESC \ as text, so that no script line holds a raw escape.
$script:Esc = [string][char]27
$script:St = $script:Esc + [string][char]92

# The program under test: clears the screen, runs the vtreader with the query
# from a file and the given wait, drops <Name>.done, sleeps. $Until is the
# C-escaped byte string that ends the wait early. Returns the config text.
function New-KittyConfig {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$QueryFile,
        [int]$WaitMs = 25000,
        [string]$Until,
        [int]$GotMax = -1,
        [string]$Extra = ''
    )
    $tmp = $script:Sbx.Tmp
    $fwd = { param($p) $p -replace '\\', '/' }
    $fake = New-FakeExe -Path (Join-Path $tmp 'bin/vtreader.exe') -Kind vtreader
    $ps1 = Join-Path $tmp "$Name.ps1"
    $lines = @(
        '$e = [string][char]27'
        '[Console]::Out.Write($e + "[2J" + $e + "[H")'
        '[Console]::Out.Flush()'
        ('$env:FAKE_QUERY_FILE = ''' + $QueryFile + '''')
        ('$env:FAKE_WAIT_MS = "' + $WaitMs + '"')
    )
    if ($Until) { $lines += ('$env:FAKE_UNTIL = ''' + $Until + '''') }
    if ($GotMax -ge 0) { $lines += ('$env:FAKE_GOT_MAX = "' + $GotMax + '"') }
    $lines += @(
        ('& "' + (& $fwd $fake) + '"')
        ('Set-Content -LiteralPath "' + (& $fwd (Join-Path $tmp "$Name.done")) + '" -Value done')
        'Start-Sleep -Seconds 600'
    )
    [IO.File]::WriteAllText($ps1, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
    "command = direct:powershell.exe -NoProfile -NoLogo -File $(& $fwd $ps1)`nwindows-conpty = auto`nconfirm-close-surface = false`n$Extra`n"
}

# Everything the terminal sent back, as a list of @{ Meta; Data } (Meta is a
# hashtable of the ":" fields, mime/pw already base64-decoded; Data the
# payload bytes). Raw is the ASCII of the reply.
function Read-KittyReply([string]$Raw) {
    $packets = @()
    foreach ($part in ($Raw -split ([regex]::Escape($script:Esc + ']5522;')))) {
        if (-not $part) { continue }
        $end = $part.IndexOf($script:St)
        $body = if ($end -ge 0) { $part.Substring(0, $end) } else { $part }
        $semi = $body.IndexOf(';')
        $metaText = if ($semi -ge 0) { $body.Substring(0, $semi) } else { $body }
        $payload = if ($semi -ge 0) { $body.Substring($semi + 1) } else { '' }
        $meta = @{}
        foreach ($kv in ($metaText -split ':')) {
            $eq = $kv.IndexOf('=')
            if ($eq -lt 0) { continue }
            $k = $kv.Substring(0, $eq); $v = $kv.Substring($eq + 1)
            if ($k -eq 'mime' -or $k -eq 'pw') { try { $v = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($v)) } catch { } }
            $meta[$k] = $v
        }
        $data = [byte[]]@()
        if ($payload) { try { $data = [Convert]::FromBase64String($payload) } catch { } }
        $packets += , @{ Meta = $meta; Data = $data }
    }
    , $packets
}

# The concatenated payload of the DATA packets of one MIME type, or $null.
function Get-KittyData($Packets, [string]$Mime) {
    $ms = $null
    foreach ($p in $Packets) {
        if ($p.Meta['status'] -eq 'DATA' -and $p.Meta['mime'] -eq $Mime) {
            if ($null -eq $ms) { $ms = New-Object IO.MemoryStream }
            $ms.Write($p.Data, 0, $p.Data.Length)
        }
    }
    if ($null -eq $ms) { return $null }
    , $ms.ToArray()
}

# The status packets in order (OK, DATA, DONE, EPERM ...).
function Get-KittyStatuses($Packets) { @($Packets | ForEach-Object { [string]$_.Meta['status'] }) }

# Selects the whole screen and copies it; the vtreader printed "GOT:<hex>" on
# it. Overwrites the clipboard: call it last. Returns the reply bytes as ASCII
# text, and the optional "LEN:<n>" the vtreader printed when capped.
function Read-KittyScreen($G) {
    if (-not (Invoke-GhosttyAction -Class $G.Class -Action 'select_all')) { throw 'select_all was not performed' }
    if (-not (Invoke-GhosttyAction -Class $G.Class -Action 'copy_to_clipboard')) { throw 'copy_to_clipboard was not performed' }
    Update-ClipboardMark
    Start-Sleep -Milliseconds 300
    $text = Invoke-ClipboardRetry { [System.Windows.Forms.Clipboard]::GetText() }
    $flat = $text -replace '\s', ''
    $m = [regex]::Match($flat, 'GOT:([0-9a-f]*)')
    if (-not $m.Success) { throw "the screen has no GOT: line: $text" }
    $len = [regex]::Match($flat, 'LEN:(\d+)')
    $hex = $m.Groups[1].Value
    # A cap may leave an odd digit count when the line wraps over LEN.
    if ($hex.Length % 2) { $hex = $hex.Substring(0, $hex.Length - 1) }
    [pscustomobject]@{
        Raw = [Text.Encoding]::GetEncoding(28591).GetString((ConvertFrom-HexString $hex))
        Len = if ($len.Success) { [int]$len.Groups[1].Value } else { -1 }
    }
}

function Find-KittyDialog($G, [double]$TimeoutSec = 8) {
    Wait-Until -TimeoutSec $TimeoutSec -PollMs 100 -Condition {
        [GhosttyE2e.Win]::TopLevel([uint32]$G.Pid, 'GhosttyDialog') | Select-Object -First 1
    }
}

function Test-KittyDialogOpen($G) {
    $null -ne ([GhosttyE2e.Win]::TopLevel([uint32]$G.Pid, 'GhosttyDialog') | Select-Object -First 1)
}

function Close-KittyDialog($Dialog, [ValidateSet('Allow', 'Deny')][string]$How) {
    if ($How -eq 'Allow') {
        # TDM_CLICK_BUTTON (WM_USER + 102) on the Allow button (id 100), as paste-confirm does.
        [void][GhosttyE2e.Win]::PostMessageW($Dialog, 0x466, [IntPtr]100, [IntPtr]::Zero)
    } else {
        # Enter takes the default button, Deny.
        [GhosttyE2e.Win]::PostEnter($Dialog)
    }
    $closed = Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { -not [GhosttyE2e.Win]::IsWindow($Dialog) }
    if (-not $closed) { throw "the dialog is still open 5 s after $How" }
}

# Builds a clipboard snapshot from @{ Format = id-or-name; Bytes = byte[] } items.
function New-ClipSnapshot($Items) {
    $objs = @()
    foreach ($i in $Items) {
        $id = if ($i.Format -is [string]) { [GhosttyKitty.Tool]::RegisterClipboardFormatW($i.Format) } else { [uint32]$i.Format }
        $objs += , ([object[]]@([uint32]$id, [byte[]]$i.Bytes))
    }
    [pscustomobject]@{ Items = $objs }
}

# Puts a snapshot on the clipboard as our own write (the restore mark follows).
function Set-ClipSnapshot($Snapshot) {
    $mark = Get-ClipboardMarkPath
    $clean = (Test-Path -LiteralPath $mark) -and ([uint32](Get-Content -LiteralPath $mark -Raw).Trim() -eq [uint32](Get-ClipboardSequence))
    Set-ClipboardSnapshot $Snapshot
    if ($clean) { Update-ClipboardMark }
}

function Get-ClipFormatBytes($Snapshot, $Format) {
    $id = if ($Format -is [string]) { [GhosttyKitty.Tool]::RegisterClipboardFormatW($Format) } else { [uint32]$Format }
    foreach ($item in $Snapshot.Items) { if ([uint32]$item[0] -eq [uint32]$id) { return , ([byte[]]$item[1]) } }
    $null
}

# The CF_HTML block holding $Fragment.
function New-CfHtml([string]$Fragment) {
    $pre = '<html><body>' + "`r`n" + '<!--StartFragment-->'
    $post = '<!--EndFragment-->' + "`r`n" + '</body></html>'
    $headerLen = 105
    $u = New-Object Text.UTF8Encoding $false
    $startFrag = $headerLen + $u.GetByteCount($pre)
    $endFrag = $startFrag + $u.GetByteCount($Fragment)
    $end = $endFrag + $u.GetByteCount($post)
    $h = 'Version:0.9' + "`r`n" + ('StartHTML:{0:D10}' -f $headerLen) + "`r`n" + ('EndHTML:{0:D10}' -f $end) + "`r`n" +
        ('StartFragment:{0:D10}' -f $startFrag) + "`r`n" + ('EndFragment:{0:D10}' -f $endFrag) + "`r`n"
    $bytes = $u.GetBytes($h + $pre + $Fragment + $post)
    , ([byte[]]($bytes + [byte[]]@(0)))
}

function ConvertTo-UnicodeTextBytes([string]$Text) {
    , ([byte[]]([Text.Encoding]::Unicode.GetBytes($Text) + [byte[]]@(0, 0)))
}

# The fragment of a CF_HTML block, or $null.
function Get-CfHtmlFragment([byte[]]$Block) {
    $s = [Text.Encoding]::UTF8.GetString($Block)
    $m = [regex]::Match($s, '(?s)<!--StartFragment-->(.*)<!--EndFragment-->')
    if ($m.Success) { $m.Groups[1].Value } else { $null }
}

# A window shot of $Hwnd saved to $Path; the number of pixels near ($R,$G,$B).
function Measure-ShotColor([IntPtr]$Hwnd, [string]$Path, [int[]]$Rgb, [int]$Tol = 40) {
    Save-WindowShot $Hwnd $Path
    $bmp = New-Object Drawing.Bitmap $Path
    try {
        $hit = 0
        for ($y = 0; $y -lt $bmp.Height; $y += 2) {
            for ($x = 0; $x -lt $bmp.Width; $x += 2) {
                $c = $bmp.GetPixel($x, $y)
                if ([Math]::Abs($c.R - $Rgb[0]) -le $Tol -and [Math]::Abs($c.G - $Rgb[1]) -le $Tol -and [Math]::Abs($c.B - $Rgb[2]) -le $Tol) { $hit++ }
            }
        }
        $hit
    } finally { $bmp.Dispose() }
}
