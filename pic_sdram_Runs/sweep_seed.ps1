# sweep_seed.ps1 -- place-seed sweep for the current netlist.
# Pure ASCII ONLY. Non-ASCII comments make PS5.1 silently comment out the
# param(...) lines, the loop runs zero times, and the script still exits 0.
#
# Two traps this script defends against:
#  1) TD can CRASH in the router ("Oops! coredump", rc -1073741819). A crashed
#     run leaves the PREVIOUS pic_sdram.bit on disk, which looks like a result.
#     => delete the bit before every run; only trust it if it reappears AND the
#        log has a "Timing Mode : final" block.
#  2) syn is NOT re-run: the netlist does not depend on the place seed.

$ErrorActionPreference = 'Continue'

$TD   = "D:/relate_to_study/TD/bin/td_commands_prompt.exe"
$TCL  = "D:/relate_to_study/TD/doc/scripts/DefaultFlow.tcl"
$PHY  = "D:\fpga_anlu\C_1\C_1\pic_sdram_Runs\phy_1"
$ORIG = Join-Path $PHY "settings.cfg.orig"
$BIT  = Join-Path $PHY "pic_sdram.bit"

$base = [System.IO.File]::ReadAllText($ORIG)
$seeds = 1..10
if ($args.Count -gt 0) { $seeds = $args | ForEach-Object { [int]$_ } }

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
        Write-Output ("seed {0,2}  *** CRASH / no final timing ***  (rc={1}, log {2})" -f $s, $rc, $log.Name)
        continue
    }

    $tail = $txt.Substring($ms[$ms.Count-1].Index)
    $a = [regex]::Match($tail, "Setup\s*:\s*WNS\s*(-?\d+)ps[\s\S]{0,160}?NUM_FEPS\s+(\d+)")
    $b = [regex]::Match($tail, "Hold\s*:\s*WNS\s*(-?\d+)ps")
    $setup = if ($a.Success) { $a.Groups[1].Value } else { "?" }
    $feps  = if ($a.Success) { $a.Groups[2].Value } else { "?" }
    $hold  = if ($b.Success) { $b.Groups[1].Value } else { "?" }

    $md5 = (Get-FileHash $BIT -Algorithm MD5).Hash
    Copy-Item $BIT (Join-Path $PHY "sweep_seed$s.bit") -Force

    Write-Output ("seed {0,2}  setup {1,6}ps  hold {2,5}ps  FEPS {3}  {4}" -f $s, $setup, $hold, $feps, $md5)
}

# leave the working tree with the default settings again
[System.IO.File]::WriteAllText((Join-Path $PHY "settings.cfg"), $base)
Write-Output ""
Write-Output "done. pick a seed, then set it and re-run phy once more."
