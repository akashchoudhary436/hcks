<#
.SYNOPSIS
  Recover ONLY images + GIFs + videos from WhatsApp Web IndexedDB.
#>

param(
    [string]$Root   = ".",
    [string]$OutDir = (Join-Path (Get-Location) ("recovered_wa_media_" + (Get-Date -Format "yyyyMMdd_HHmmss")))
)

$ErrorActionPreference = "Continue"
function Log($m, $c="White") { Write-Host $m -ForegroundColor $c }

# =============================================================
# STEP 1 — KILL CHROME
# =============================================================
Log "`n▶ Step 1: Killing Chrome" Cyan
foreach ($n in @("chrome","msedge","brave","chromedriver")) {
    $p = Get-Process -Name $n -ErrorAction SilentlyContinue
    if ($p) { $p | ForEach-Object { try { $_.Kill() } catch {} }; Log "  Killed $n" Green }
}
Log "  Waiting 5s for file locks..." Gray
Start-Sleep -Seconds 5
if (Get-Process -Name chrome -ErrorAction SilentlyContinue) {
    Stop-Process -Name chrome -Force -ErrorAction SilentlyContinue; Start-Sleep 3
}

# =============================================================
# STEP 2 — DETECT + CREATE FOLDERS
# =============================================================
Log "`n▶ Step 2: Detecting WhatsApp folders" Cyan
$waBlob = Join-Path $Root "https_web.whatsapp.com_0.indexeddb.blob"
$waDb   = Join-Path $Root "https_web.whatsapp.com_0.indexeddb.leveldb"

if (-not (Test-Path $waDb))   { Log "  ❌ Missing leveldb" Red; exit 1 }
if (-not (Test-Path $waBlob)) { Log "  ❌ Missing blob"    Red; exit 1 }

$dirImages = Join-Path $OutDir "images"
$dirVideos = Join-Path $OutDir "videos"
$dirGifs   = Join-Path $OutDir "gifs"

foreach ($d in @($dirImages,$dirVideos,$dirGifs)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}
Log "  Output: $OutDir" Green

# =============================================================
# STEP 3 — READ LEVELDB FOR MEDIA KEYS
# =============================================================
Log "`n▶ Step 3: Extracting decryption keys" Cyan

function Read-LevelDB {
    param([string]$Folder)
    $entries = @{}

    # WAL (.log)
    Get-ChildItem $Folder -Filter "*.log" -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $data = [IO.File]::ReadAllBytes($_.FullName)
            $pos = 0
            while ($pos -lt $data.Length - 7) {
                $bo = $pos % 32768
                $hl = 32768 - $bo
                if ($hl -lt 7) { $pos += $hl; continue }
                $len = [BitConverter]::ToUInt16($data, $pos+4)
                $typ = $data[$pos+6]
                if ($len -eq 0 -or ($pos+7+$len) -gt $data.Length) { break }
                if ($typ -eq 1 -or $typ -eq 2) {
                    $pl = $data[($pos+7)..($pos+6+$len)]
                    $p=0; $kl=0; $sh=0
                    while ($p -lt $pl.Length) {
                        $b=$pl[$p];$p++
                        $kl=$kl -bor (($b -band 0x7F) -shl $sh);$sh+=7
                        if (-not ($b -band 0x80)){break}
                    }
                    if ($kl -gt 0 -and ($p+$kl) -le $pl.Length) {
                        $kb = $pl[$p..($p+$kl-1)]
                        $key = [BitConverter]::ToString($kb)
                        $p += $kl
                        $vl=0;$sh=0
                        while ($p -lt $pl.Length) {
                            $b=$pl[$p];$p++
                            $vl=$vl -bor (($b -band 0x7F) -shl $sh);$sh+=7
                            if (-not ($b -band 0x80)){break}
                        }
                        if ($vl -gt 0 -and ($p+$vl) -le $pl.Length) {
                            $entries[$key] = [byte[]]$pl[$p..($p+$vl-1)]
                        }
                    }
                }
                $pos += 7 + $len
            }
        } catch {}
    }

    # SST (.ldb / .sst) — scan for 32-byte keys
    Get-ChildItem $Folder -Include "*.ldb","*.sst" -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $data = [IO.File]::ReadAllBytes($_.FullName)
            for ($i = 0; $i -le $data.Length - 32; $i++) {
                $u=0;$s=@{}
                for ($j=0;$j -lt 32;$j++) {
                    $b=$data[$i+$j]
                    if (-not $s.ContainsKey($b)){$s[$b]=$true;$u++}
                }
                if ($u -ge 26) {
                    $h = [BitConverter]::ToString($data[$i..($i+31)]) -replace '-',''
                    if (-not $entries.ContainsKey("k_$h")) {
                        $entries["k_$h"] = $data[$i..($i+31)]
                    }
                }
            }
        } catch {}
    }
    return $entries
}

$db = Read-LevelDB -Folder $waDb
Log "  Entries: $($db.Count)" Gray

# Collect keys
$keys = @(); $seen = @{}
foreach ($k in $db.Keys) {
    $v = $db[$k]
    if ($v.Length -eq 32) {
        $h = [BitConverter]::ToString($v)
        if (-not $seen.ContainsKey($h)) { $seen[$h]=$true; $keys += ,$v }
    }
    if ($v.Length -ge 48) {
        for ($off=0; $off -le ($v.Length-32); $off++) {
            $w = $v[$off..($off+31)]
            $u=@{}; foreach ($b in $w){$u[$b]=$true}
            if ($u.Count -ge 26) {
                $h = [BitConverter]::ToString($w)
                if (-not $seen.ContainsKey($h)) { $seen[$h]=$true; $keys += ,$w }
            }
        }
    }
}
Log "  Key candidates: $($keys.Count)" Green

# =============================================================
# STEP 4 — DECRYPTION
# =============================================================
function HKDF-Expand([byte[]]$Prk,[byte[]]$Info,[int]$Len) {
    $okm = New-Object System.Collections.Generic.List[byte]
    $t = [byte[]]::new(0); $i=1
    while ($okm.Count -lt $Len) {
        $h = [System.Security.Cryptography.HMACSHA256]::new($Prk)
        $buf = New-Object System.Collections.Generic.List[byte]
        $buf.AddRange($t);$buf.AddRange($Info);$buf.Add([byte]$i)
        $t = $h.ComputeHash($buf.ToArray()); $h.Dispose()
        $okm.AddRange($t); $i++
    }
    return $okm.GetRange(0,$Len).ToArray()
}

function Decrypt-WaMedia {
    param([byte[]]$Enc,[byte[]]$Key)
    if ($Enc.Length -lt 42 -or $Key.Length -ne 32) { return $null }
    try {
        $salt = [byte[]]::new(32)
        $hm = [System.Security.Cryptography.HMACSHA256]::new($salt)
        $prk = $hm.ComputeHash($Key); $hm.Dispose()
        $info = [Text.Encoding]::UTF8.GetBytes("WhatsApp Media Keys")
        $exp = HKDF-Expand $prk $info 112
        $iv = $exp[0..15]; $ck = $exp[16..47]; $mk = $exp[48..79]
        $clen = $Enc.Length - 10
        $ct = $Enc[0..($clen-1)]
        $mac = $Enc[$clen..($Enc.Length-1)]
        $hm2 = [System.Security.Cryptography.HMACSHA256]::new($mk)
        $toMac = New-Object System.Collections.Generic.List[byte]
        $toMac.AddRange($iv);$toMac.AddRange($ct)
        $calc = $hm2.ComputeHash($toMac.ToArray())[0..9]
        $hm2.Dispose()
        for ($i=0;$i -lt 10;$i++){ if ($mac[$i] -ne $calc[$i]) { return $null } }
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Mode='CBC';$aes.Padding='PKCS7';$aes.Key=$ck;$aes.IV=$iv
        $d = $aes.CreateDecryptor()
        $out = $d.TransformFinalBlock($ct,0,$ct.Length)
        $d.Dispose();$aes.Dispose()
        return $out
    } catch { return $null }
}

# Only detect images / gifs / videos
function Get-Type([byte[]]$b) {
    if ($b.Length -lt 12) { return @($null,$null) }
    if ($b[0] -eq 0xFF -and $b[1] -eq 0xD8 -and $b[2] -eq 0xFF) { return @("jpg","images") }
    if ($b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47) { return @("png","images") }
    if ($b[0] -eq 0x47 -and $b[1] -eq 0x49 -and $b[2] -eq 0x46 -and $b[3] -eq 0x38) { return @("gif","gifs") }
    if ($b[0] -eq 0x52 -and $b[1] -eq 0x49 -and $b[2] -eq 0x46 -and $b[3] -eq 0x46 `
        -and $b[8] -eq 0x57 -and $b[9] -eq 0x45 -and $b[10] -eq 0x42 -and $b[11] -eq 0x50) {
        $isAnim = $false
        for ($q=12; $q -lt [Math]::Min(64,$b.Length-4); $q++) {
            if ($b[$q] -eq 0x41 -and $b[$q+1] -eq 0x4E -and $b[$q+2] -eq 0x49 -and $b[$q+3] -eq 0x4D) {
                $isAnim = $true; break
            }
        }
        if ($isAnim) { return @("webp","gifs") }
        return @("webp","images")
    }
    if ($b[4] -eq 0x66 -and $b[5] -eq 0x74 -and $b[6] -eq 0x79 -and $b[7] -eq 0x70) {
        $brand = [Text.Encoding]::ASCII.GetString($b[8..11])
        if ($brand -match '^M4A|^M4B') { return @($null,$null) }
        if ($brand -match '^3gp')      { return @("3gp","videos") }
        if ($brand -match '^qt')       { return @("mov","videos") }
        return @("mp4","videos")
    }
    if ($b[0] -eq 0x1A -and $b[1] -eq 0x45 -and $b[2] -eq 0xDF -and $b[3] -eq 0xA3) {
        return @("webm","videos")
    }
    return @($null,$null)
}

# =============================================================
# STEP 5 — PROCESS ALL BLOBS
# =============================================================
Log "`n▶ Step 5: Decrypting + sorting blobs" Cyan

$cImg=0; $cVid=0; $cGif=0; $cFail=0
$total = (Get-ChildItem $waBlob -Recurse -File -ErrorAction SilentlyContinue).Count
Log "  Total blobs: $total" Gray

$i=0
Get-ChildItem $waBlob -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    $i++
    if ($i % 50 -eq 0) { Log ("    [{0}/{1}] img={2} vid={3} gif={4} fail={5}" -f $i,$total,$cImg,$cVid,$cGif,$cFail) Gray }

    try {
        $enc = [IO.File]::ReadAllBytes($_.FullName)
        if ($enc.Length -lt 42) { $cFail++; return }

        $dec = $null
        foreach ($k in $keys) {
            $dec = Decrypt-WaMedia $enc $k
            if ($dec) { break }
        }
        $data = if ($dec) { $dec } else { $enc }

        $ti = Get-Type $data
        $ext = $ti[0]; $cat = $ti[1]
        if (-not $ext) { $cFail++; return }

        $dir = switch ($cat) {
            "images" { $dirImages }
            "videos" { $dirVideos }
            "gifs"   { $dirGifs }
        }
        $dest = Join-Path $dir ("$($_.Name).$ext")
        [IO.File]::WriteAllBytes($dest, $data)
        switch ($cat) {
            "images" { $script:cImg++ }
            "videos" { $script:cVid++ }
            "gifs"   { $script:cGif++ }
        }
    } catch { $cFail++ }
}

Log "`n  ✅ Images : $cImg" Green
Log "     Videos : $cVid" Green
Log "     GIFs   : $cGif" Green
Log "     Skipped: $cFail (non-media)" Yellow

# =============================================================
# STEP 6 — SCAN LEVELDB FOR EMBEDDED IMAGES/GIFS
# =============================================================
Log "`n▶ Step 6: Scanning leveldb for embedded images" Cyan
$eImg=0; $eGif=0

Get-ChildItem $waDb -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $b = [IO.File]::ReadAllBytes($_.FullName)
        for ($j=0; $j -lt $b.Length-3; $j++) {
            if ($b[$j] -eq 0xFF -and $b[$j+1] -eq 0xD8 -and $b[$j+2] -eq 0xFF) {
                $end=-1
                for ($k=$j+3; $k -lt [Math]::Min($b.Length-1, $j+3000000); $k++) {
                    if ($b[$k] -eq 0xFF -and $b[$k+1] -eq 0xD9) { $end=$k+1; break }
                }
                if ($end -gt $j) {
                    $slice = $b[$j..$end]
                    [IO.File]::WriteAllBytes((Join-Path $dirImages ("ldb_thumb_$eImg.jpg")), $slice)
                    $eImg++; $j = $end
                }
            }
        }
        for ($j=0; $j -lt $b.Length-3; $j++) {
            if ($b[$j] -eq 0x89 -and $b[$j+1] -eq 0x50 -and $b[$j+2] -eq 0x4E -and $b[$j+3] -eq 0x47) {
                $len = [Math]::Min(2097152, $b.Length - $j)
                $slice = $b[$j..($j+$len-1)]
                [IO.File]::WriteAllBytes((Join-Path $dirImages ("ldb_$eImg.png")), $slice)
                $eImg++; $j += $len - 1
            }
        }
        for ($j=0; $j -lt $b.Length-3; $j++) {
            if ($b[$j] -eq 0x47 -and $b[$j+1] -eq 0x49 -and $b[$j+2] -eq 0x46 -and $b[$j+3] -eq 0x38) {
                $len = [Math]::Min(5000000, $b.Length - $j)
                $slice = $b[$j..($j+$len-1)]
                [IO.File]::WriteAllBytes((Join-Path $dirGifs ("ldb_$eGif.gif")), $slice)
                $eGif++; $j += $len - 1
            }
        }
    } catch {}
}
Log "  Embedded images: $eImg | GIFs: $eGif" Green

# =============================================================
# STEP 7 — REASSEMBLE SPLIT VIDEOS
# =============================================================
Log "`n▶ Step 7: Reassembling split videos" Cyan

$groups = @{}
foreach ($f in Get-ChildItem $dirVideos -File -ErrorAction SilentlyContinue) {
    if ($f.BaseName -match '^(\d+)') {
        $num = $Matches[1]
        $prefix = $num.Substring(0, [Math]::Max(1, $num.Length - 1))
        $g = $f.Extension + "_" + $prefix
        if (-not $groups.ContainsKey($g)) { $groups[$g] = @() }
        $groups[$g] += $f
    }
}
$merged = 0
foreach ($g in $groups.GetEnumerator()) {
    if ($g.Value.Count -lt 2) { continue }
    $sorted = $g.Value | Sort-Object Name
    $ext = $sorted[0].Extension
    $out = Join-Path $dirVideos ("merged_$($g.Key)$ext")
    $fs = [IO.File]::Create($out)
    foreach ($f in $sorted) {
        $b = [IO.File]::ReadAllBytes($f.FullName)
        $fs.Write($b, 0, $b.Length)
    }
    $fs.Close()
    $check = [IO.File]::ReadAllBytes($out)
    if ((Get-Type $check)[0]) {
        $sorted | ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
        $merged++
    } else {
        Remove-Item $out -Force -ErrorAction SilentlyContinue
    }
}
Log "  Merged: $merged" Green

# =============================================================
# STEP 8 — CLEANUP + SUMMARY
# =============================================================
foreach ($d in @($dirImages,$dirVideos,$dirGifs)) {
    if ((Get-ChildItem $d -File -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item $d -Force -ErrorAction SilentlyContinue
    }
}

$all = Get-ChildItem $OutDir -Recurse -File -ErrorAction SilentlyContinue
$size = ($all | Measure-Object -Property Length -Sum).Sum

Log "`n═══════════════════════════════════════" Magenta
Log "  MEDIA RECOVERY COMPLETE" Magenta
Log "═══════════════════════════════════════" Magenta
Log "  Output : $OutDir"
Log "  Images : $((Get-ChildItem $dirImages -File -EA SilentlyContinue).Count)"
Log "  Videos : $((Get-ChildItem $dirVideos -File -EA SilentlyContinue).Count)"
Log "  GIFs   : $((Get-ChildItem $dirGifs   -File -EA SilentlyContinue).Count)"
Log "  Total  : $($all.Count) files, $([Math]::Round($size/1MB,2)) MB"
Log "═══════════════════════════════════════" Magenta

if ($all.Count -gt 0) {
    Log "`n✅ Opening folder..." Green
    Start-Process explorer.exe $OutDir
} else {
    Log "`n⚠️ Nothing recovered — WhatsApp keys may be encrypted. Use WhatsApp Desktop → Export chat instead." Yellow
}
Log "`nDone." Green
