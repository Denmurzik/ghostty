# Checked output streams for the stream-integrity scenario. Dot-source it.
#
# New-CheckedStream writes a file of numbered lines, each ending in the
# CRC-32 of the rest of the line:
#
#   00000042 <printable ASCII payload, 16..60 chars> 1a2b3c4d
#
# Every line is at most 78 characters, so it fits an 80-column terminal
# without wrapping. Line i is a function of i alone, so the checker can
# regenerate what the terminal should hold.
#
# Test-CheckedStream reads a screen dump (Ghostty's write_screen_file,
# plain text, one terminal row per line) and compares the stream lines in it
# with the generated ones. It reports every missing, changed or extra line
# with its line number and, for a changed line, the first column that
# differs.
#
# Keep this file ASCII only (Windows PowerShell 5.1 reads a BOM-less script
# as ANSI).

if (-not ('GhosttyE2e.Stream' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name Stream -MemberDefinition @'
static readonly uint[] crcTable = MakeCrcTable();

static uint[] MakeCrcTable() {
    uint[] t = new uint[256];
    for (uint n = 0; n < 256; n++) {
        uint c = n;
        for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        t[n] = c;
    }
    return t;
}

public static uint Crc32(string s) {
    uint c = 0xFFFFFFFFu;
    foreach (char ch in s) c = crcTable[(c ^ (byte)ch) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

// Line i of the stream, without the newline.
public static string Line(long i) {
    ulong x = (ulong)i * 0x9E3779B97F4A7C15UL + 0x30B;
    int len = 16 + (int)(x % 45);
    StringBuilder sb = new StringBuilder(80);
    sb.Append(i.ToString("D8"));
    sb.Append(' ');
    for (int k = 0; k < len; k++) {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17;
        // Printable ASCII; a space only inside the payload, never at its
        // ends (the dump may trim trailing blanks).
        char c = (char)(0x21 + (int)(x % 94));
        if (k > 0 && k < len - 1 && (x >> 40) % 7 == 0) c = ' ';
        sb.Append(c);
    }
    string body = sb.ToString();
    return body + " " + Crc32(body).ToString("x8");
}

// Writes lines until the file holds at least minBytes; returns the count.
public static long Write(string path, long minBytes) {
    long n = 0, bytes = 0;
    using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read, 1 << 20)) {
        byte[] buf = new byte[96];
        while (bytes < minBytes) {
            string l = Line(n) + "\n";
            int len = Encoding.ASCII.GetBytes(l, 0, l.Length, buf, 0);
            fs.Write(buf, 0, len);
            bytes += len;
            n++;
        }
    }
    return n;
}

// "nnnnnnnn ... crc" with a matching CRC: the line index, else -1.
static long ParseValid(string l) {
    if (l.Length < 18 || l[8] != ' ' || l[l.Length - 9] != ' ') return -1;
    long idx;
    if (!long.TryParse(l.Substring(0, 8), out idx)) return -1;
    string body = l.Substring(0, l.Length - 9);
    return Crc32(body).ToString("x8") == l.Substring(l.Length - 8) ? idx : -1;
}

static string Describe(string want, string got) {
    int col = 0;
    while (col < want.Length && col < got.Length && want[col] == got[col]) col++;
    string kind;
    if (got.Length == want.Length - 1 && want.Remove(col, 1) == got) kind = "1 char missing ('" + want[col] + "')";
    else if (got.Length == want.Length + 1 && got.Remove(col, 1) == want) kind = "1 char extra ('" + got[col] + "')";
    else if (got.Length == want.Length) kind = "changed";
    else kind = "length " + got.Length + " instead of " + want.Length;
    return kind + " at column " + (col + 1);
}

public class Result {
    public long Expected;
    public long Matched;
    public long Missing;
    public long Changed;
    public long Extra;
    public bool SawEnd;
    public long FirstDumpLine = -1;
    public List<string> Problems = new List<string>();
    public void Note(string s) { if (Problems.Count < 40) Problems.Add(s); }
}

// Checks the dump against lines 0..count-1 followed by endMarker. Only
// lines after the dump's first stream line are looked at (the shell's
// prompt and command come before it).
public static Result Check(string dumpPath, long count, string endMarker) {
    Result r = new Result();
    r.Expected = count;
    long next = 0;
    long dumpLine = 0;
    bool started = false;
    foreach (string raw in File.ReadLines(dumpPath, Encoding.UTF8)) {
        dumpLine++;
        string l = raw.TrimEnd(' ', '\r');
        if (!started) {
            // The first stream line, as far as it is recognisable.
            if (l.Length >= 9 && l[8] == ' ' && char.IsDigit(l[0]) && char.IsDigit(l[7])) {
                started = true;
                r.FirstDumpLine = dumpLine;
            } else {
                continue;
            }
        }
        if (next >= count) {
            if (l == endMarker) { r.SawEnd = true; break; }
            if (l.Length == 0) continue;
            r.Extra++;
            r.Note("dump line " + dumpLine + ": extra line after the stream: '" + l + "'");
            continue;
        }

        string want = Line(next);
        if (l == want) { r.Matched++; next++; continue; }

        long idx = ParseValid(l);
        if (idx > next && idx < count) {
            // A valid later line: everything in between is gone.
            r.Missing += idx - next;
            r.Note("dump line " + dumpLine + ": stream lines " + next + ".." + (idx - 1) + " missing (" + (idx - next) + " lines)");
            r.Matched++;
            next = idx + 1;
        } else if (idx >= 0) {
            r.Extra++;
            r.Note("dump line " + dumpLine + ": stream line " + idx + " again or out of order, expected line " + next);
        } else if (l == endMarker) {
            r.Missing += count - next;
            r.Note("dump line " + dumpLine + ": end marker after stream line " + (next - 1) + ", " + (count - next) + " lines missing");
            r.SawEnd = true;
            next = count;
            break;
        } else {
            r.Changed++;
            r.Note("dump line " + dumpLine + ": stream line " + next + " " + Describe(want, l) + "\n    want '" + want + "'\n    got  '" + l + "'");
            next++;
        }
    }
    if (next < count && !r.SawEnd) r.Missing += count - next;
    return r;
}
'@ -UsingNamespace 'System.Text', 'System.IO', 'System.Collections.Generic'
}

function New-CheckedStream([string]$Path, [double]$MegaBytes) {
    $lines = [GhosttyE2e.Stream]::Write($Path, [long]($MegaBytes * 1MB))
    [pscustomobject]@{ Path = $Path; Lines = $lines; Bytes = (Get-Item -LiteralPath $Path).Length }
}

function Test-CheckedStream([string]$DumpPath, [long]$Lines, [string]$EndMarker) {
    [GhosttyE2e.Stream]::Check($DumpPath, $Lines, $EndMarker)
}
