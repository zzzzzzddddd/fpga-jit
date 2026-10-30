# 澶?seed 鎵弿锛氬崟璺戞祦绋嬭惤涓嶄笅鏃跺簭鏃讹紝鐢ㄥ畠鎹竴涓竷灞€鍐嶈瘯銆?#   鍘熺悊锛欴efaultFlow.tcl 鐨?prepare 浼氭妸 $phyWildParams 鎸変笁鍏冪粍
#   閫愪釜 set_param锛屾墍浠ュ彧瑕佸湪 settings.cfg 閲屽涓€琛?#       set phyWildParams {place seed N}
#   鍗曡窇娴佺▼灏变細鐢ㄧ N 鍙峰竷灞€绉嶅瓙璺?opt_place銆?#   鈽?涓嶇敤鏀逛换浣?RTL 鈽?鈥斺€?缃戣〃涓€瀛椾笉鍔紝鍙槸鎹釜鎽嗘硶銆?#   璺戝畬涓€杞氨鎶?settings.cfg 杩樺師鎴?settings.cfg.orig銆?param([int[]]$Seeds = @(1,2,3,4,5,6,7,8))

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

$log = @()
$winner = $null

foreach ($s in $Seeds) {
    # 鎶?phyWildParams 閭ｄ竴琛屾崲鎴愬綋鍓?seed锛堜笉瀛樺湪灏辫拷鍔狅級
    $body = $base
    $line = "set phyWildParams {place seed $s}"
    if ($body -match '(?m)^set phyWildParams .*$') {
        $body = $body -replace '(?m)^set phyWildParams .*$', $line
    } else {
        $body = $body.TrimEnd() + "`r`n" + $line + "`r`n"
    }
    Set-Content -Path $cfg -Value $body -Encoding ascii

    if (Test-Path $ts) { Remove-Item $ts -Force }

    Write-Host "=== seed $s : running (count=$($Seeds.Count)) ==="; if ($env:SWEEP_STUB) { continue }
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

# 杩樺師
Copy-Item $orig $cfg -Force

Write-Host ""
Write-Host "================= SWEEP SUMMARY ================="
$log | ForEach-Object { Write-Host $_ }
if ($winner) { Write-Host "WINNER: seed $winner" } else { Write-Host "WINNER: none" }

