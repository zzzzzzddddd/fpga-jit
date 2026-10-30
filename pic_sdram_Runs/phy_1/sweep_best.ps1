# Same mechanism as sweep_seed.ps1, but does NOT stop at the first passing
# seed: it runs every seed in the list, keeps a bitstream per passing seed
# (pic_sdram_seedN.bit), and reports all results so the best margin can be
# picked deliberately. Holder of nothing: settings.cfg is restored at the end.
#
# NOTE: keep this file ASCII-only (see sweep_seed.ps1 for why).
param([int[]]$Seeds = @(3,4,5,6,7))

$ErrorActionPreference = 'Stop'
$here  = "D:\fpga_anlu\C_1\C_1\pic_sdram_Runs\phy_1"
$td    = "D:/relate_to_study/TD/bin/td_commands_prompt.exe"
$flow  = "D:/relate_to_study/TD/doc/scripts/DefaultFlow.tcl"
$orig  = Join-Path $here "settings.cfg.orig"
$cfg   = Join-Path $here "settings.cfg"
$ts    = Join-Path $here "pic_sdram_phy.ts"
$bit   = Join-Path $here "pic_sdram.bit"

Set-Location $here
$base = Get-Content $orig -Raw

$rows = @()

foreach ($s in $Seeds) {
    $body = $base
    $line = "set phyWildParams {place seed $s}"
    if ($body -match '(?m)^set phyWildParams .*$') {
        $body = $body -replace '(?m)^set phyWildParams .*$', $line
    } else {
        $body = $body.TrimEnd() + "`r`n" + $line + "`r`n"
    }
    Set-Content -Path $cfg -Value $body -Encoding ascii

    if (Test-Path $ts) { Remove-Item $ts -Force }

    Write-Host "=== seed $s : running ==="
    & $td $flow *> "seed_$s.log"

    if (-not (Test-Path $ts)) {
        $rows += [pscustomobject]@{ seed=$s; setup=$null; hold=$null; note="NO REPORT (flow failed)" }
        continue
    }
    $txt = (Get-Content $ts -Raw).Trim() -replace "\r?\n", " | "
    $ms  = [regex]::Match($txt, 'SWNS:\s*(-?[\d.]+)ns')
    $mh  = [regex]::Match($txt, 'HWNS:\s*(-?[\d.]+)ns')
    if (-not ($ms.Success -and $mh.Success)) {
        $rows += [pscustomobject]@{ seed=$s; setup=$null; hold=$null; note="UNPARSED: $txt" }
        continue
    }
    $sw = [double]$ms.Groups[1].Value
    $hw = [double]$mh.Groups[1].Value
    $note = "FAIL"
    if ($sw -ge 0 -and $hw -ge 0) {
        Copy-Item $bit "pic_sdram_seed$s.bit" -Force
        $note = "pass (bit kept)"
    }
    $rows += [pscustomobject]@{ seed=$s; setup=$sw; hold=$hw; note=$note }
}

Copy-Item $orig $cfg -Force

Write-Host ""
Write-Host "================= SWEEP SUMMARY ================="
$rows | ForEach-Object {
    Write-Host ("seed {0,-3} setup {1,8}  hold {2,8}  {3}" -f $_.seed, $_.setup, $_.hold, $_.note)
}
$pass = $rows | Where-Object { $_.note -like 'pass*' }
if ($pass) {
    $best = $pass | Sort-Object { [Math]::Min($_.setup, $_.hold) } -Descending | Select-Object -First 1
    Write-Host ("BEST: seed {0}  (setup {1}, hold {2})" -f $best.seed, $best.setup, $best.hold)
} else {
    Write-Host "BEST: none"
}
