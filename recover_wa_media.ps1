#Requires -Version 5.1
<#
  Silent WhatsApp Web media recovery from Chrome profile.
  - Runs hidden (no console window, no popups).
  - Kills all Chrome processes without asking.
  - No log output. Writes only recovered files + a small _DONE.txt marker.
  - Save partial videos with -SavePartial.

  Recommended launch:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File .\recover.ps1
#>
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path (Get-Location).Path ('recovered_wa_media_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))),
    [switch]$SavePartial,
    [long]$MaxFileBytes = 1500MB,
    [switch]$NoSelfHide   # internal: set when re-launching hidden
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# ---- Self-hide: if running in a visible console, relaunch hidden and exit ----
if (-not $NoSelfHide) {
    try {
        $host.UI.RawUI.WindowTitle | Out-Null  # touch host
        $proc = Get-Process -Id $PID
        if ($proc.MainWindowHandle -ne 0) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName  = (Get-Process -Id $PID).Path
            $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -NoSelfHide{1}{2}{3}' -f `
                $PSCommandPath,
                $(if ($SavePartial) { ' -SavePartial' } else { '' }),
                (' -OutDir "{0}"' -f $OutDir),
                (' -MaxFileBytes {0}' -f $MaxFileBytes)
            $psi.UseShellExecute = $true
            $psi.WindowStyle     = [System.Diagnostics.ProcessWindowStyle]::Hidden
            $psi.CreateNoWindow  = $true
            [System.Diagnostics.Process]::Start($psi) | Out-Null
            exit 0
        }
    } catch { }
}

$OutDir = [System.IO.Path]::GetFullPath($OutDir)
$Dirs = @{
    images  = Join-Path $OutDir 'images'
    videos  = Join-Path $OutDir 'videos'
    partial = Join-Path $OutDir 'partial_videos'
}
$DoneMarker = Join-Path $OutDir '_DONE.txt'
$ChromeUserData = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'
$SourceRelPaths = @(
    'IndexedDB\https_web.whatsapp.com_0.indexeddb.blob',
    'IndexedDB\https_web.whatsapp.com_0.indexeddb.leveldb',
    'Service Worker\CacheStorage',
    'Service Worker\ScriptCache',
    'Cache\Cache_Data'
)

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# Silent logger: no console, no log file. Kept as a no-op so the rest of
# the script stays readable and future debugging is easy.
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO'
    )
    # Intentionally silent.
}

# ---------------------------------------------------------------
# Structural carver (unchanged)
# ---------------------------------------------------------------
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public sealed class CarvedMedia
{
    public string Kind;
    public string Category;
    public bool   Complete;
    public long   Missing;
    public long   Offset;
    public byte[] Data;
}

public static class MediaCarver
{
    static readonly HashSet<string> KnownBoxes = new HashSet<string>
    {
        "ftyp","moov","mdat","free","skip","wide","uuid","moof","mfra",
        "sidx","styp","pdin","meta","udta"
    };

    public static List<CarvedMedia> Carve(byte[] b)
    {
        var found = new List<CarvedMedia>();
        int n = b.Length;
        int p = 0;
        while (p + 12 <= n)
        {
            int end;
            if (b[p] == 0xFF && b[p + 1] == 0xD8 && b[p + 2] == 0xFF)
            {
                if (TryJpeg(b, p, out end))
                {
                    found.Add(Make("jpg", "images", p, end - p, true, 0, b));
                    p = end; continue;
                }
            }
            else if (b[p] == 0x89 && b[p + 1] == 0x50 && b[p + 2] == 0x4E && b[p + 3] == 0x47)
            {
                if (TryPng(b, p, out end))
                {
                    found.Add(Make("png", "images", p, end - p, true, 0, b));
                    p = end; continue;
                }
            }
            else if (b[p] == 0x47 && b[p + 1] == 0x49 && b[p + 2] == 0x46 && b[p + 3] == 0x38)
            {
                if (TryGif(b, p, out end))
                {
                    found.Add(Make("gif", "images", p, end - p, true, 0, b));
                    p = end; continue;
                }
            }
            else if (p >= 4 && b[p] == 0x66 && b[p + 1] == 0x74 && b[p + 2] == 0x79 && b[p + 3] == 0x70)
            {
                int start = p - 4;
                long ftypSize = BE32(b, start);
                if (ftypSize >= 12 && ftypSize <= 1024)
                {
                    long mend; bool moov, mdat, trunc; long missing; string brand;
                    WalkMp4(b, start, out mend, out moov, out mdat, out trunc, out missing, out brand);
                    bool isAudio = brand.StartsWith("M4A") || brand.StartsWith("M4B") || brand.StartsWith("M4P");
                    if (!isAudio && (moov || mdat))
                    {
                        bool complete = moov && mdat && !trunc;
                        string kind = brand.StartsWith("qt") ? "mov" : (brand.StartsWith("3gp") ? "3gp" : "mp4");
                        found.Add(Make(kind, "videos", start, (int)(mend - start), complete, complete ? 0 : missing, b));
                        p = (int)mend; continue;
                    }
                }
            }
            p++;
        }
        return found;
    }

    static CarvedMedia Make(string kind, string cat, int off, int len, bool complete, long missing, byte[] src)
    {
        var d = new byte[len];
        Buffer.BlockCopy(src, off, d, 0, len);
        return new CarvedMedia { Kind = kind, Category = cat, Offset = off, Complete = complete, Missing = missing, Data = d };
    }

    static uint BE32(byte[] b, int p)
    {
        return ((uint)b[p] << 24) | ((uint)b[p + 1] << 16) | ((uint)b[p + 2] << 8) | b[p + 3];
    }

    static string Ascii(byte[] b, int off)
    {
        if (off < 0 || off + 4 > b.Length) return "";
        return Encoding.ASCII.GetString(b, off, 4);
    }

    static void WalkMp4(byte[] b, int start, out long end, out bool hasMoov, out bool hasMdat,
                        out bool truncated, out long missing, out string brand)
    {
        long n = b.Length, p = start;
        end = start; hasMoov = false; hasMdat = false; truncated = false; missing = 0; brand = "";
        int count = 0;
        while (p + 8 <= n)
        {
            long size = BE32(b, (int)p);
            string type = Ascii(b, (int)p + 4);
            if (!KnownBoxes.Contains(type)) break;
            if (count == 0 && type != "ftyp") break;

            long header = 8;
            if (size == 1)
            {
                if (p + 16 > n) { truncated = true; break; }
                size = ((long)BE32(b, (int)p + 8) << 32) | BE32(b, (int)p + 12);
                header = 16;
            }
            else if (size == 0) size = n - p;

            if (size < header) break;
            if (count == 0) brand = Ascii(b, (int)p + 8);

            if (p + size > n)
            {
                truncated = true;
                missing = p + size - n;
                if (type == "mdat") { hasMdat = true; end = n; }
                if (type == "moov") hasMoov = true;
                break;
            }

            if (type == "moov") hasMoov = true;
            if (type == "mdat") hasMdat = true;
            p += size;
            end = p;
            count++;
        }
    }

    static bool TryPng(byte[] b, int s, out int end)
    {
        end = s;
        int n = b.Length;
        long p = s + 8;
        while (p + 12 <= n)
        {
            long len = BE32(b, (int)p);
            string type = Ascii(b, (int)p + 4);
            long next = p + 12 + len;
            if (next > n || type.Length != 4) return false;
            foreach (char c in type) if (!char.IsLetter(c)) return false;
            if (type == "IEND") { end = (int)next; return true; }
            p = next;
        }
        return false;
    }

    static bool TryJpeg(byte[] b, int s, out int end)
    {
        end = s;
        int n = b.Length;
        int p = s + 2;

        while (true)
        {
            if (p + 4 > n || b[p] != 0xFF) return false;
            byte m = b[p + 1];
            if (m == 0xFF) { p++; continue; }
            if (m == 0xD9) { end = p + 2; return true; }
            if (m == 0x01 || (m >= 0xD0 && m <= 0xD7)) { p += 2; continue; }
            int len = (b[p + 2] << 8) | b[p + 3];
            if (len < 2) return false;
            p += 2 + len;
            if (m == 0xDA) break;
        }

        while (p + 1 < n)
        {
            if (b[p] != 0xFF) { p++; continue; }
            byte m = b[p + 1];
            if (m == 0x00 || m == 0xFF) { p++; continue; }
            if (m >= 0xD0 && m <= 0xD7) { p += 2; continue; }
            if (m == 0xD9) { end = p + 2; return true; }
            if (m >= 0xC0 && p + 4 <= n)
            {
                int len = (b[p + 2] << 8) | b[p + 3];
                if (len < 2) return false;
                p += 2 + len;
                continue;
            }
            return false;
        }
        return false;
    }

    static bool TryGif(byte[] b, int s, out int end)
    {
        end = s;
        int n = b.Length;
        if (s + 13 > n) return false;
        byte flags = b[s + 10];
        int p = s + 13;
        if ((flags & 0x80) != 0) p += 3 * (1 << ((flags & 0x07) + 1));
        while (p < n)
        {
            byte t = b[p];
            if (t == 0x3B) { end = p + 1; return true; }
            if (t == 0x21)
            {
                p += 2;
                if (!SkipSubBlocks(b, ref p)) return false;
            }
            else if (t == 0x2C)
            {
                if (p + 10 > n) return false;
                byte f = b[p + 9];
                p += 10;
                if ((f & 0x80) != 0) p += 3 * (1 << ((f & 0x07) + 1));
                p += 1;
                if (!SkipSubBlocks(b, ref p)) return false;
            }
            else return false;
        }
        return false;
    }

    static bool SkipSubBlocks(byte[] b, ref int p)
    {
        while (true)
        {
            if (p >= b.Length) return false;
            int size = b[p++];
            if (size == 0) return true;
            p += size;
            if (p > b.Length) return false;
        }
    }
}
"@

# ---------------------------------------------------------------
# Main
# ---------------------------------------------------------------
$work = $null
try {
    if (-not (Test-Path -LiteralPath $ChromeUserData)) { exit 1 }

    $profiles = @(Get-ChildItem -LiteralPath $ChromeUserData -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match '^(Default|Profile \d+)$' })
    if ($profiles.Count -eq 0) { exit 1 }

    # Kill all Chrome without asking. Kill crash handler first to avoid dialogs.
    Get-Process -Name 'chrome_crashpad_handler' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process -Name 'chrome' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $work = Join-Path $env:TEMP ('wa_work_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    foreach ($prof in $profiles) {
        foreach ($rel in $SourceRelPaths) {
            $src = Join-Path $prof.FullName $rel
            if (-not (Test-Path -LiteralPath $src)) { continue }
            $dst = Join-Path (Join-Path $work $prof.Name) $rel
            try {
                New-Item -ItemType Directory -Path (Split-Path $dst -Parent) -Force | Out-Null
                Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
            } catch { }
        }
    }

    foreach ($d in $Dirs.Values) { New-Item -ItemType Directory -Path $d -Force | Out-Null }

    $files = @(Get-ChildItem -LiteralPath $work -Recurse -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Length -ge 64 -and $_.Length -le $MaxFileBytes })

    $sha  = [System.Security.Cryptography.SHA256]::Create()
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $stats = [ordered]@{ images = 0; videos = 0; partialSaved = 0; incompleteSkipped = 0; duplicates = 0; unreadable = 0 }

    foreach ($file in $files) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            $found = [MediaCarver]::Carve($bytes)
        } catch { $stats.unreadable++; continue }

        foreach ($m in $found) {
            # Drop tiny stub MP4s that were false positives
            if ($m.Category -eq 'videos' -and $m.Data.Length -lt 64KB -and -not $m.Complete) {
                $stats.incompleteSkipped++; continue
            }
            if (-not $m.Complete -and -not $SavePartial) { $stats.incompleteSkipped++; continue }

            $hash = [BitConverter]::ToString($sha.ComputeHash($m.Data)).Replace('-', '').Substring(0, 16).ToLower()
            if (-not $seen.Add($hash)) { $stats.duplicates++; continue }

            if ($m.Category -eq 'images')  { $dir = $Dirs.images;  $stats.images++ }
            elseif ($m.Complete)           { $dir = $Dirs.videos;  $stats.videos++ }
            else                           { $dir = $Dirs.partial; $stats.partialSaved++ }

            $name = '{0}_{1}.{0}' -f $m.Kind, $hash
            $path = Join-Path $dir $name
            try { [System.IO.File]::WriteAllBytes($path, $m.Data) } catch { }
        }
    }

    foreach ($d in $Dirs.Values) {
        if (Test-Path -LiteralPath $d) {
            if (-not (Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Final "finished" marker — the only thing written besides media files.
    $summary = @(
        "Finished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Images: $($stats.images)"
        "Videos: $($stats.videos)"
        "Partial videos saved: $($stats.partialSaved)"
        "Incomplete skipped: $($stats.incompleteSkipped)"
        "Duplicates: $($stats.duplicates)"
        "Unreadable: $($stats.unreadable)"
        "Output: $OutDir"
    ) -join "`r`n"
    try { [System.IO.File]::WriteAllText($DoneMarker, $summary, [System.Text.Encoding]::UTF8) } catch { }
}
catch { }
finally {
    if ($work -and (Test-Path -LiteralPath $work)) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
