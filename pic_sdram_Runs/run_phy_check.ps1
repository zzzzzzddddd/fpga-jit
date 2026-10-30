# run_phy_check.ps1 -- run phy once with the CURRENT settings.cfg and classify.
# Pure ASCII ONLY. (Non-ASCII comments make PS5.1 silently comment out the
# param(...) lines, the loop runs zero times, and the script still exits 0.)
#
# Prints, for the run it just did:
#   1) whether the log has "Timing Mode : final"   (a crashed run leaves the
#      PREVIOUS bit on disk -- file existence proves nothing)
#   2) Setup / Hold / FEPS
#   3) every hold fix classified VIDEO vs AUDIO vs other
#   4) per-path-group Min HWNS from final_timing.rpt  (which domain holds
#      the worst hold slack -- that is where a thin margin actually lives)

$TD   = "D:/relate_to_study/TD/bin/td_commands_prompt.exe"
$TCL  = "D:/relate_to_study/TD/doc/scripts/DefaultFlow.tcl"
$PHY  = "D:\fpga_anlu\C_1\C_1\pic_sdram_Runs\phy_1"
$BIT  = Join-Path $PHY "pic_sdram.bit"
$RPT  = Join-Path $PHY "final_timing.rpt"

$VIDEO = @("read_buf","write_buf","u_overlay","u_panel",
           "u_video_axi_stream_receiver","frame_fifo","App_rd_addr")
$AUDIO = @("U_audio_sample_packet_2_channel","u_wav_loader")

if (Test-Path $BIT) { Remove-Item $BIT -Force }
Set-Location $PHY
& $TD $TCL | Out-Null
Write-Output ("rc=" + $LASTEXITCODE)

$log = Get-ChildItem (Join-Path $PHY "*.log") |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
$txt = [System.IO.File]::ReadAllText($log.FullName)
$ms  = [regex]::Matches($txt, "Timing Mode\s*:\s*final")
Write-Output ("log = " + $log.Name + "   final=" + $ms.Count + "   bit=" + (Test-Path $BIT))

if ($ms.Count -eq 0 -or -not (Test-Path $BIT)) {
    Write-Output "*** CRASH / no final timing -- do not trust the bit on disk ***"
    exit 1
}

$tail = $txt.Substring($ms[$ms.Count-1].Index)
$a = [regex]::Match($tail, "Setup\s*:\s*WNS\s*(-?\d+)ps[\s\S]{0,160}?NUM_FEPS\s+(\d+)")
$b = [regex]::Match($tail, "Hold\s*:\s*WNS\s*(-?\d+)ps")
Write-Output ("Setup=" + $a.Groups[1].Value + "ps  Hold=" + $b.Groups[1].Value + "ps  FEPS=" + $a.Groups[2].Value)
Write-Output ("MD5 = " + (Get-FileHash $BIT -Algorithm MD5).Hash)

Write-Output ""
Write-Output "--- hold fixes ---"
$nv = 0; $na = 0; $no = 0
foreach ($h in [regex]::Matches($txt, "fix hold violation on net (\S+) endpin (\S+) slack (-?\d+)ps")) {
    $e = $h.Groups[2].Value
    $cls = "other"
    foreach ($k in $VIDEO) { if ($e -match [regex]::Escape($k)) { $cls = "VIDEO" } }
    if ($cls -eq "other") { foreach ($k in $AUDIO) { if ($e -match [regex]::Escape($k)) { $cls = "audio" } } }
    if ($cls -eq "VIDEO") { $nv++ } elseif ($cls -eq "audio") { $na++ } else { $no++ }
    Write-Output ("  [" + $cls + "] " + $e + "   " + $h.Groups[3].Value + "ps")
}
Write-Output ("  => VIDEO=" + $nv + "  AUDIO=" + $na + "  other=" + $no)

Write-Output ""
Write-Output "--- per-path-group Min HWNS (which domain owns the worst hold) ---"
if (Test-Path $RPT) {
    $r = [System.IO.File]::ReadAllText($RPT)
    foreach ($m in [regex]::Matches($r, "Path Group\s*:\s*([^\n]+)\n(?:[^\n]*\n){0,3}?[^\n]*Min\s*:\s*HWNS\s+(-?[\d.]+)ns")) {
        Write-Output ("  " + $m.Groups[1].Value.Trim().PadRight(38) + " Min HWNS = " + $m.Groups[2].Value + " ns")
    }
    $g = [regex]::Match($r, "HWNS:\s*(-?[\d.]+)ns")
    Write-Output ("  global HWNS = " + $g.Groups[1].Value + " ns")
} else { Write-Output "  (no final_timing.rpt)" }
