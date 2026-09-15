@echo off
setlocal
REM =====================================================================
REM  PC Repair Kit - double-click entry point.
REM
REM  A .cmd file exists (rather than telling people to right-click a .ps1
REM  and pick "Run with PowerShell") because that path silently fails on
REM  machines with a restrictive execution policy, and because the person
REM  running this is often not the person who built the drive.
REM
REM  This self-elevates: half the whitelist (DISM, chkdsk, restore points,
REM  Defender exclusions) simply does not work without admin, and a
REM  non-elevated run would produce a confusing half-repair.
REM =====================================================================

cd /d "%~dp0"

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo   Asking for administrator permission...
    echo   Click YES on the prompt that appears.
    echo.
    REM Re-launch elevated. Any arguments given to this .cmd (e.g.
    REM -RepairMode Check, -BackupMode Skip) are carried across the
    REM elevation boundary; without this they were silently dropped.
    if "%~1"=="" (
        powershell -NoProfile -ExecutionPolicy Bypass -Command ^
            "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -Command ^
            "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)

echo.
echo   ==========================================
echo     PC REPAIR KIT
echo   ==========================================
echo.
echo   Starting up. This window will show progress.
echo   Leave it open and leave the drive plugged in.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Repair.ps1" %*
set EXITCODE=%errorlevel%

echo.
if %EXITCODE%==0 (
    echo   ==========================================
    echo     FINISHED
    echo   ==========================================
    echo   A full record was saved to the logs folder on this drive.
) else if %EXITCODE%==3 (
    echo   ==========================================
    echo     COULD NOT START - NO INTERNET
    echo   ==========================================
    echo   The repair assistant needs an internet connection to think.
    echo   The tools on this drive still work by hand - see
    echo   docs\tool-invocations.md for the exact commands.
) else if %EXITCODE%==4 (
    echo   ==========================================
    echo     COULD NOT START - SAFETY CHECK FAILED
    echo   ==========================================
    echo   The command guard that limits what the assistant may run did
    echo   not block a test command on this PC, so the repair was not
    echo   started. See the logs folder; nothing on the PC was changed.
) else if %EXITCODE%==5 (
    echo   ==========================================
    echo     COULD NOT START - SIGN-IN EXPIRED OR INVALID
    echo   ==========================================
    echo   The drive's saved sign-in for the repair assistant was rejected.
    echo   Rebuild the drive on your own PC (see BUILD.md) to refresh it.
    echo   Nothing on this PC was changed.
) else (
    echo   ==========================================
    echo     STOPPED EARLY - see the messages above
    echo   ==========================================
    echo   Nothing was necessarily broken. Check the logs folder on this
    echo   drive for the full record before assuming a repair completed.
)
echo.
echo   Press any key to close this window.
pause >nul
endlocal
