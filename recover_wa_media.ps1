param(
    [string]$OutSuffix = (Get-Date -Format "yyyyMMdd_HHmmss")
)

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }

Write-Host "[1/7] Killing Chrome processes..."
foreach ($n in @("chrome","chromedriver")) {
    $p = Get-Process -Name $n -ErrorAction SilentlyContinue
    if ($p) { $p | ForEach-Object { try { $_.Kill() } catch {} } }
}
Start-Sleep -Seconds 5
if (Get-Process -Name chrome -ErrorAction SilentlyContinue) {
    Stop-Process -Name chrome -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}

Write-Host "[2/7] Locating Chrome profiles..."
$chromeRoots = @()
$baseRoot = "$env:LOCALAPPDATA\Google\Chrome\User Data"
if (Test-Path $baseRoot) {
    Get-ChildItem $baseRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match '^(Default|Profile \d+|Guest Profile)$') { $chromeRoots += $_.FullName }
    }
}
if ($chromeRoots.Count -eq 0) { Write-Host "No Chrome profiles found."; exit 1 }

Write-Host "[3/7] Building search paths..."
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
$searchPaths = @($searchPaths | Select-Object -Unique)

Write-Host "[4/7] Preparing LOCAL output folder (no webhook)..."
$OutDir = Join-Path $ScriptDir ("recovered_wa_media_" + $OutSuffix)
$dirImages = Join-Path $OutDir "images"
$dirVideos = Join-Path $OutDir "videos"
$dirGifs   = Join-Path $OutDir "gifs"
foreach ($d in @($dirImages,$dirVideos,$dirGifs)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
Write-Host "Output: $OutDir"

Write-Host "[5/7] Loading helper..."
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;

public class WaHelper {

    static readonly string[] HKDF_INFOS = new string[] {
        "WhatsApp Image Keys",
        "WhatsApp Video Keys",
        "WhatsApp Audio Keys",
        "WhatsApp Document Keys",
        "WhatsApp Sticker Keys",
        "WhatsApp Media Keys"
    };

    // ---------------- Key harvesting ----------------
    public static List<byte[]> ExtractKeys(string path) {
        var result = new List<byte[]>();
        byte[] data;
        try { data = File.ReadAllBytes(path); } catch { return result; }
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

    // ---------------- MP4 box walking ----------------
    static bool IsPrintableType(byte[] b, int pos) {
        if (pos + 8 > b.Length) return false;
        for (int i = 4; i < 8; i++) {
            byte c = b[pos + i];
            if (c < 0x20 || c > 0x7E) return false;
        }
        return true;
    }

    static long ReadBoxSize(byte[] b, int pos, out int headerSize) {
        headerSize = 8;
        if (pos + 8 > b.Length) return -1;
        long size = ((long)b[pos] << 24) | ((long)b[pos+1] << 16) | ((long)b[pos+2] << 8) | b[pos+3];
        if (size == 1) {
            if (pos + 16 > b.Length) return -1;
            size = 0;
            for (int k = 0; k < 8; k++) size = (size << 8) | (uint)b[pos+8+k];
            headerSize = 16;
        }
        return size;   // 0 = "box extends to EOF"
    }

    // Returns end offset of the valid MP4 (never rejects — falls back to b.Length when truncated).
    // Returns -1 only if 'start' is not a valid ftyp.
    static int GetMp4Range(byte[] b, int start, out bool wasTruncated) {
        wasTruncated = false;
        if (start + 8 > b.Length) return -1;
        string firstType = Encoding.ASCII.GetString(b, start + 4, 4);
        if (firstType != "ftyp") return -1;

        bool hasMoov = false, hasMdat = false, hasMoof = false;
        int pos = start;
        int lastGoodEnd = start;
        bool sawFtyp = false;

        while (pos + 8 <= b.Length) {
            if (!IsPrintableType(b, pos)) break;
            int hs;
            long boxSize = ReadBoxSize(b, pos, out hs);
            if (boxSize < 0) { wasTruncated = true; lastGoodEnd = b.Length; break; }
            string type = Encoding.ASCII.GetString(b, pos + 4, 4);

            if (type == "ftyp" && sawFtyp) break;         // second ftyp => next video
            if (type == "ftyp") sawFtyp = true;
            if (type == "moov") hasMoov = true;
            if (type == "mdat") hasMdat = true;
            if (type == "moof") hasMoof = true;

            if (boxSize == 0) { lastGoodEnd = b.Length; pos = b.Length; break; }
            if (boxSize < hs) { wasTruncated = true; lastGoodEnd = b.Length; break; }
            if (pos + boxSize > b.Length) {                // truncated box (usually mdat)
                wasTruncated = true;
                lastGoodEnd = b.Length;                    // accept everything we have
                break;
            }
            pos += (int)boxSize;
            lastGoodEnd = pos;
        }

        if (lastGoodEnd <= start + 8) return -1;
        // Require at least a moov header AND some media data (mdat or moof) to be playable
        if (!hasMoov)  return -1;
        if (!hasMdat && !hasMoof) return -1;
        return lastGoodEnd;
    }

    // ---------------- Image / GIF end-finders ----------------
    static int FindJpegEnd(byte[] b, int start) {
        for (int j = start + 3; j < b.Length - 1; j++) {
            if (b[j] == 0xFF && b[j+1] == 0xD9) {
                if (j - start > 100) return j + 2;
                return -1;
            }
        }
        return -1;
    }

    static int FindPngEnd(byte[] b, int start) {
        if (start + 8 > b.Length) return -1;
        if (!(b[start]==0x89 && b[start+1]==0x50 && b[start+2]==0x4E && b[start+3]==0x47 &&
              b[start+4]==0x0D && b[start+5]==0x0A && b[start+6]==0x1A && b[start+7]==0x0A)) return -1;
        int pos = start + 8;
        while (pos + 12 <= b.Length) {
            long len = ((long)b[pos] << 24) | ((long)b[pos+1] << 16) | ((long)b[pos+2] << 8) | b[pos+3];
            if (len < 0 || len > 0x7FFFFFFFL) return -1;
            if (pos + 12 + (int)len > b.Length) return -1;
            string type = Encoding.ASCII.GetString(b, pos + 4, 4);
            if (type == "IEND") return pos + 12 + (int)len;
            pos += 12 + (int)len;
        }
        return -1;
    }

    static int FindGifEnd(byte[] b, int start) {
        if (start + 13 > b.Length) return -1;
        int pos = start + 6 + 7;
        byte packed = b[start + 10];
        if ((packed & 0x80) != 0) pos += 3 * (1 << ((packed & 0x07) + 1));
        while (pos < b.Length) {
            byte id = b[pos];
            if (id == 0x3B) return pos + 1;
            if (id == 0x2C) {
                if (pos + 10 > b.Length) return -1;
                byte lctPacked = b[pos + 9];
                pos += 10;
                if ((lctPacked & 0x80) != 0) pos += 3 * (1 << ((lctPacked & 0x07) + 1));
                if (pos >= b.Length) return -1;
                pos++;
                while (pos < b.Length) {
                    int s = b[pos]; pos++;
                    if (s == 0) break;
                    pos += s;
                }
            } else if (id == 0x21) {
                pos += 2;
                while (pos < b.Length) {
                    int s = b[pos]; pos++;
                    if (s == 0) break;
                    pos += s;
                }
            } else return -1;
        }
        return -1;
    }

    static string ClassifyByMagic(byte[] d, int p) {
        if (p + 12 > d.Length) return null;
        if (d[p] == 0xFF && d[p+1] == 0xD8 && d[p+2] == 0xFF) return "jpg";
        if (d[p] == 0x89 && d[p+1] == 0x50 && d[p+2] == 0x4E && d[p+3] == 0x47) return "png";
        if (d[p] == 0x47 && d[p+1] == 0x49 && d[p+2] == 0x46 && d[p+3] == 0x38) return "gif";
        if (d[p+4] == 0x66 && d[p+5] == 0x74 && d[p+6] == 0x79 && d[p+7] == 0x70) {
            string brand = Encoding.ASCII.GetString(d, p + 8, 4);
            if (brand.StartsWith("M4A") || brand.StartsWith("M4B")) return null;
            if (brand.StartsWith("3gp")) return "3gp";
            if (brand.StartsWith("qt"))  return "mov";
            return "mp4";
        }
        return null;
    }

    // ---------------- Save (accept everything playable) ----------------
    static bool TrySaveMedia(byte[] data, int start, string kind,
                             string dirImages, string dirVideos, string dirGifs,
                             Dictionary<string, bool> hashDedup,
                             out int newPos) {
        newPos = start;
        byte[] payload = null;
        string ext = null, dir = null, prefix = null;
        bool truncated = false;

        if (kind == "jpg") {
            int end = FindJpegEnd(data, start);
            if (end < 0) return false;
            if (end - start < 100) return false;
            payload = new byte[end - start];
            Array.Copy(data, start, payload, 0, payload.Length);
            ext = "jpg"; dir = dirImages; prefix = "img"; newPos = end;
        }
        else if (kind == "png") {
            int end = FindPngEnd(data, start);
            if (end < 0) return false;
            if (end - start < 100) return false;
            payload = new byte[end - start];
            Array.Copy(data, start, payload, 0, payload.Length);
            ext = "png"; dir = dirImages; prefix = "img"; newPos = end;
        }
        else if (kind == "gif") {
            int end = FindGifEnd(data, start);
            if (end < 0) return false;
            if (end - start < 100) return false;
            payload = new byte[end - start];
            Array.Copy(data, start, payload, 0, payload.Length);
            ext = "gif"; dir = dirGifs; prefix = "gif"; newPos = end;
        }
        else if (kind == "mp4" || kind == "mov" || kind == "3gp") {
            int end = GetMp4Range(data, start, out truncated);
            if (end < 0) return false;
            if (end - start < 100) return false;
            payload = new byte[end - start];
            Array.Copy(data, start, payload, 0, payload.Length);
            ext = kind; dir = dirVideos; prefix = "vid"; newPos = end;
        }
        else return false;

        string hash;
        using (var sha = SHA256.Create()) {
            hash = Convert.ToBase64String(sha.ComputeHash(payload));
        }
        if (hashDedup.ContainsKey(hash)) return false;     // duplicate — but newPos is still set

        hashDedup[hash] = true;
        string fn = prefix + "_" + Guid.NewGuid().ToString("N").Substring(0, 10)
                    + (truncated ? "_partial" : "") + "." + ext;
        File.WriteAllBytes(Path.Combine(dir, fn), payload);
        return true;
    }

    // ---------------- Main scanner ----------------
    public static int ScanFileForMedia(string path, string dirImages, string dirVideos, string dirGifs,
                                       bool tryDecrypt, List<byte[]> keys, bool isBlobFile,
                                       Dictionary<string, bool> hashDedup) {
        int saved = 0;
        byte[] b;
        try { b = File.ReadAllBytes(path); } catch { return 0; }
        if (b.Length < 12) return 0;

        // 1) Whole-file decryption (blob files — the complete video is stored as one encrypted blob)
        if (isBlobFile && keys.Count > 0) {
            foreach (byte[] key in keys) {
                byte[] dec = DecryptMedia(b, key);
                if (dec != null && dec.Length > 12) {
                    saved += ExtractFromDecrypted(dec, dirImages, dirVideos, dirGifs, hashDedup);
                    if (saved > 0) break;
                }
            }
        }

        // 2) Raw scan for unencrypted media (also handles multiple ftyp-separated videos)
        int pos = 0;
        while (pos < b.Length - 12) {
            bool maybe = false;
            if (pos + 3  <= b.Length && b[pos]   == 0xFF && b[pos+1] == 0xD8 && b[pos+2] == 0xFF) maybe = true;
            if (pos + 8  <= b.Length && b[pos]   == 0x89 && b[pos+1] == 0x50 && b[pos+2] == 0x4E && b[pos+3] == 0x47) maybe = true;
            if (pos + 6  <= b.Length && b[pos]   == 0x47 && b[pos+1] == 0x49 && b[pos+2] == 0x46 && b[pos+3] == 0x38) maybe = true;
            if (pos + 12 <= b.Length && b[pos+4] == 0x66 && b[pos+5] == 0x74 && b[pos+6] == 0x79 && b[pos+7] == 0x70) maybe = true;

            if (maybe) {
                string kind = ClassifyByMagic(b, pos);
                if (kind != null) {
                    int newPos;
                    if (TrySaveMedia(b, pos, kind, dirImages, dirVideos, dirGifs, hashDedup, out newPos)) saved++;
                    if (newPos > pos) { pos = newPos; continue; }
                }
            }
            pos++;
        }

        // 3) Try embedded decryption (non-blob files)
        if (tryDecrypt && saved == 0 && keys.Count > 0 && b.Length > 500 && !isBlobFile) {
            foreach (byte[] key in keys) {
                byte[] dec = DecryptMedia(b, key);
                if (dec != null && dec.Length > 12) {
                    saved += ExtractFromDecrypted(dec, dirImages, dirVideos, dirGifs, hashDedup);
                    if (saved > 0) break;
                }
            }
            if (saved == 0) {
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
                                saved += ExtractFromDecrypted(dec, dirImages, dirVideos, dirGifs, hashDedup);
                                if (saved > 0) break;
                            }
                        }
                        if (saved > 0) break;
                    }
                    if (saved > 0) break;
                }
            }
        }

        return saved;
    }

    static int ExtractFromDecrypted(byte[] dec, string dirImages, string dirVideos, string dirGifs,
                                    Dictionary<string, bool> hashDedup) {
        int saved = 0;
        int pos = 0;
        while (pos < dec.Length - 12) {
            string kind = ClassifyByMagic(dec, pos);
            if (kind != null) {
                int newPos;
                if (TrySaveMedia(dec, pos, kind, dirImages, dirVideos, dirGifs, hashDedup, out newPos)) saved++;
                if (newPos > pos) { pos = newPos; continue; }
            }
            pos++;
        }
        return saved;
    }

    // ---------------- Decryption (all HKDF info strings) ----------------
    public static byte[] DecryptMedia(byte[] enc, byte[] key) {
        if (enc.Length < 42 || key.Length != 32) return null;
        foreach (string info in HKDF_INFOS) {
            byte[] r = DecryptMediaWithInfo(enc, key, info);
            if (r != null) return r;
        }
        return null;
    }

    static byte[] DecryptMediaWithInfo(byte[] enc, byte[] key, string info) {
        try {
            byte[] salt = new byte[32];
            byte[] prk;
            using (var hmac = new HMACSHA256(salt)) { prk = hmac.ComputeHash(key); }
            byte[] infoBytes = Encoding.UTF8.GetBytes(info);
            byte[] expanded = HKDFExpand(prk, infoBytes, 112);
            byte[] iv = new byte[16]; Array.Copy(expanded, 0, iv, 0, 16);
            byte[] ck = new byte[32]; Array.Copy(expanded, 16, ck, 0, 32);
            byte[] mk = new byte[32]; Array.Copy(expanded, 48, mk, 0, 32);

            int clen = enc.Length - 10;
            if (clen <= 0) return null;
            byte[] ct  = new byte[clen]; Array.Copy(enc, 0, ct, 0, clen);
            byte[] mac = new byte[10];   Array.Copy(enc, clen, mac, 0, 10);

            using (var hmac2 = new HMACSHA256(mk)) {
                byte[] toMac = new byte[iv.Length + ct.Length];
                Array.Copy(iv, 0, toMac, 0, iv.Length);
                Array.Copy(ct, 0, toMac, iv.Length, ct.Length);
                byte[] calc = hmac2.ComputeHash(toMac);
                for (int i = 0; i < 10; i++) if (mac[i] != calc[i]) return null;
            }

            using (var aes = Aes.Create()) {
                aes.Mode = CipherMode.CBC;
                aes.Padding = PaddingMode.PKCS7;
                aes.Key = ck;
                aes.IV = iv;
                using (var dec = aes.CreateDecryptor()) {
                    return dec.TransformFinalBlock(ct, 0, ct.Length);
                }
            }
        } catch { return null; }
    }

    static byte[] HKDFExpand(byte[] prk, byte[] info, int len) {
        var okm = new List<byte>();
        byte[] t = new byte[0];
        int i = 1;
        using (var hmac = new HMACSHA256(prk)) {
            while (okm.Count < len) {
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

Write-Host "[6/7] Extracting candidate keys..."
$keys = New-Object 'System.Collections.Generic.List[byte[]]'
$seen = @{}
foreach ($dbDir in $waDbDirs) {
    $logFiles = @(Get-ChildItem $dbDir -Filter "*.log" -File -ErrorAction SilentlyContinue)
    foreach ($f in $logFiles) {
        try {
            $found = [WaHelper]::ExtractKeys($f.FullName)
            foreach ($k in $found) {
                $h = [BitConverter]::ToString($k)
                if (-not $seen.ContainsKey($h)) { $seen[$h] = $true; $keys.Add($k) }
            }
        } catch {}
    }
}
Write-Host "Found $($keys.Count) candidate keys"

$hashDedup = New-Object 'System.Collections.Generic.Dictionary[string,bool]'

Write-Host "[7/7] Scanning and extracting media..."
foreach ($sp in $searchPaths) {
    $files = @(Get-ChildItem $sp -Recurse -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Length -gt 100 })
    if ($files.Count -eq 0) { continue }
    $isDbDir   = $waDbDirs   -contains $sp
    $isBlobDir = $waBlobDirs -contains $sp
    Write-Host "  Scanning: $sp ($($files.Count) files)"
    foreach ($f in $files) {
        try {
            $null = [WaHelper]::ScanFileForMedia(
                $f.FullName, $dirImages, $dirVideos, $dirGifs,
                ($isDbDir -or $isBlobDir),
                [System.Collections.Generic.List[byte[]]]$keys,
                $isBlobDir,
                $hashDedup)
        } catch {}
    }
}

foreach ($d in @($dirImages,$dirVideos,$dirGifs)) {
    if ((Get-ChildItem $d -File -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item $d -Force -ErrorAction SilentlyContinue
    }
}

$imgCount = @(Get-ChildItem $dirImages -File -ErrorAction SilentlyContinue).Count
$vidCount = @(Get-ChildItem $dirVideos -File -ErrorAction SilentlyContinue).Count
$gifCount = @(Get-ChildItem $dirGifs   -File -ErrorAction SilentlyContinue).Count
$partCount = @(Get-ChildItem $dirVideos -Filter "*_partial.*" -File -ErrorAction SilentlyContinue).Count

Write-Host ""
Write-Host "Finished."
Write-Host "Output folder : $OutDir"
Write-Host "Images        : $imgCount"
Write-Host "Videos        : $vidCount  (partial/truncated: $partCount)"
Write-Host "GIFs          : $gifCount"
Write-Host ""
Write-Host "Tip: files ending in '_partial' were cut short in the Chrome cache itself."
Write-Host "     To get the full 27-sec version, open WhatsApp Web, play the video"
Write-Host "     completely once (so Chrome caches the whole file), then re-run."
