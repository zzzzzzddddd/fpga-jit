# sweep_seed2.ps1 -- place-seed sweep that also CLASSIFIES every hold fix.
# Pure ASCII ONLY. (Non-ASCII comments make PS5.1 silently comment out the
# param(...) lines, the loop runs zero times, and the script still exits 0.)
#
# Why v2: picking a seed by max(setup) alone is what produced the v37
# speckle bug -- TD "fixes" hold violations by inserting buffers that land at
# roughly +12ps, and when they land on the live pixel path that is a wrong
# pixel on screen.  So the selection criterion is:
#     1) log must contain "Timing Mode : final"   (a crashed run leaves the
#        PREVIOUS bit on disk, which looks like a result)
#     2) count hold fixes that land on the VIDEO path -- must be 0
#     3) among those, take the best setup then hold
#
# VIDEO path  = read_buf / write_buf / u_overlay / u_panel /
#               u_video_axi_stream_receiver / frame_fifo / App_rd_addr
# AUDIO only  = U_audio_sample_packet_2_channel / u_wav_loader   (harmless)

$ErrorActionPreference = 'Continue'

$TD   = "D:/relate_to_study/TD/bin/td_commands_prompt.exe"
$TCL  = "D:/relate_to_study/TD/doc/scripts/DefaultFlow.tcl"
$PHY  = "D:\fpga_anlu\C_1\C_1\pic_sdram_Runs\phy_1"
$ORIG = Join-Path $PHY "settings.cfg.orig"
$BIT  = Join-Path $PHY "pic_sdram.bit"

$VIDEO = @("read_buf","write_buf","u_overlay","u_panel",
           "u_video_axi_stream_receiver","frame_fifo","App_rd_addr")
$AUDIO = @("U_audio_sample_packet_2_channel","u_wav_loader")

$base = [System.IO.File]::ReadAllText($ORIG)
$seeds = 1..10
if ($args.Count -gt 0) { $seeds = $args | ForEach-Object { [int]$_ } }

Write-Output "seed  setup   hold  FEPS  fixes  video  audio   verdict"
Write-Output "-------------------------------------------------------------"

foreach ($s in $seeds) {

    $cfg = $base
    if (-not $cfg.EndsWith("`n")) { $cfg += "`n" }
    $cfg += "set phyWildParams {place seed $s}`n"
    [System.IO.File]::WriteAllText((Join-Path $PHY "settings.cfg"), $cfg)

    if (Test-Path $BIT) { Remove-Item $BIT -Force }

    Set-Location $PHY
    & $TD $TCL | Out-Null
    $rc = $LASTEXITCODE

    $log = Get-ChildItem (Join-Path $PHY "*.log") |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $txt = [System.IO.File]::ReadAllText($log.FullName)

    $ms = [regex]::Matches($txt, "Timing Mode\s*:\s*final")
    if ($ms.Count -eq 0 -or -not (Test-Path $BIT)) {
        Write-Output ("{0,4}   *** CRASH / no final timing ***   (rc={1})" -f $s, $rc)
        continue
    }

    $tail = $txt.Substring($ms[$ms.Count-1].Index)
    $a = [regex]::Match($tail, "Setup\s*:\s*WNS\s*(-?\d+)ps[\s\S]{0,160}?NUM_FEPS\s+(\d+)")
    $b = [regex]::Match($tail, "Hold\s*:\s*WNS\s*(-?\d+)ps")
    $setup = if ($a.Success) { $a.Groups[1].Value } else { "?" }
    $feps  = if ($a.Success) { $a.Groups[2].Value } else { "?" }
    $hold  = if ($b.Success) { $b.Groups[1].Value } else { "?" }

    # classify every hold fix by the ENDPIN it lands on
    $nv = 0; $na = 0; $no = 0
    $vnames = @()
    foreach ($h in [regex]::Matches($txt, "fix hold violation on net \S+ endpin (\S+) slack -?\d+ps")) {
        $e = $h.Groups[1].Value
        $isv = $false
        foreach ($k in $VIDEO) { if ($e -match [regex]::Escape($k)) { $isv = $true } }
        $isa = $false
        foreach ($k in $AUDIO) { if ($e -match [regex]::Escape($k)) { $isa = $true } }
        if ($isv)      { $nv++; $vnames += ($e -replace "^.*?(read_buf|write_buf|u_overlay|u_panel|u_video_axi_stream_receiver|frame_fifo)","`$1") }
        elseif ($isa)  { $na++ }
        else           { $no++ }
    }

    $md5 = (Get-FileHash $BIT -Algorithm MD5).Hash
    Copy-Item $BIT (Join-Path $PHY ("sweep_s{0}.bit" -f $s)) -Force

    $verdict = if ($nv -eq 0) { "OK (video clean)" } else { "REJECT (video x$nv)" }
    Write-Output ("{0,4}  {1,5}   {2,4}  {3,4}   {4,3}    {5,3}    {6,3}   {7}" -f `
                   $s, $setup, $hold, $feps, ($nv+$na+$no), $nv, $na, $verdict)
    if ($nv -gt 0) {
        foreach ($v in $vnames) { Write-Output ("        video hit: " + $v) }
    }
}

[System.IO.File]::WriteAllText((Join-Path $PHY "settings.cfg"), $base)
Write-Output ""
Write-Output "done. pick a seed with video=0 (best setup/hold among those),"
Write-Output "then set it in settings.cfg and re-run phy once more."
