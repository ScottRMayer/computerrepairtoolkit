@echo off
REM =====================================================================
REM  PC Repair Kit - CHECK-ONLY entry point.
REM
REM  Same as Repair-This-PC.cmd but runs the assistant in -RepairMode Check:
REM  it diagnoses and reports what it WOULD fix without changing anything.
REM  Exists so the "safe first run" is a double-click, not a command line
REM  (a right-click "Run as administrator" on Repair-This-PC passes no
REM  arguments and would have been a full repair).
REM =====================================================================
call "%~dp0Repair-This-PC.cmd" -RepairMode Check %*
