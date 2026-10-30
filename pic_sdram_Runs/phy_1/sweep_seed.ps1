# Multi-seed sweep: when the single-run flow cannot close timing, try another
# placement.
#
# HOW IT WORKS
#   DefaultFlow.tcl's prepare proc applies $phyWildParams as (a b c) triples
#   via `set_param a b c`. So putting one line in settings.cfg
#       set phyWildParams {place seed N}
#   makes the single-run flow place with seed N. No RTL change at all --
#   the netlist is byte-identical, only the placement differs.
#   settings.cfg is restored from settings.cfg.orig when the sweep ends.
#
# WHY IT IS NEEDED
#   enable_seed is off and the placer is deterministic, so simply re-running
#   gives a bit-identical result. The seed is the only lever.
#
# NOTE: keep this file ASCII-only. PowerShell 5.1 reads .ps1 without a BOM as
#   ANSI; non-ASCII comment bytes then eat the following newline and silently
#   comment out the param() line, which makes $Seeds unbound and the loop
#   iterate zero times.
param([int[]]$Seeds = @(1,2,3,4,5,6,7,8))

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
Write-Host "DBG seeds=$($Seeds.Count)"

$log = @()
$winner = $null

foreach ($s in $Seeds) {
    # Swap the phyWildParams line to the current seed (append it if absent).
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
        $log += "seed $s : NO TIMING REPORT (flow failed) - see seed_$s.log"
        continue
    }
    $txt = (Get-Content $ts -Raw).Trim() -replace "\r?\n", " | "
    $log += "seed $s : $txt"

    $mSetup = [regex]::Match($txt, 'SWNS:\s*(-?[\d.]+)ns')
    $mHold  = [regex]::Match($txt, 'HWNS:\s*(-?[\d.]+)ns')
    if ($mSetup.Success -and $mHold.Success) {
        $sw = [double]$mSetup.Groups[1].Value
        $hw = [double]$mHold.Groups[1].Value
        if ($sw -ge 0 -and $hw -ge 0) {
            Copy-Item $bit "pic_sdram_seed$s.bit" -Force
            $log += "seed $s : *** PASS *** copied to pic_sdram_seed$s.bit"
            $winner = $s
            break
        }
    }
}

# Restore the pristine settings.cfg.
Copy-Item $orig $cfg -Force

Write-Host ""
Write-Host "================= SWEEP SUMMARY ================="
$log | ForEach-Object { Write-Host $_ }
if ($winner) { Write-Host "WINNER: seed $winner" } else { Write-Host "WINNER: none" }
