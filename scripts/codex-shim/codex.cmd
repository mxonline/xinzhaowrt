@echo off
setlocal
set "REAL_CODEX=C:\ProgramData\npm\codex.cmd"
if not exist "%REAL_CODEX%" (
  echo BLOCKED: real Codex executable not found at %REAL_CODEX% 1>&2
  exit /b 127
)
if /I "%~1"=="exec" (
  shift
  call "%REAL_CODEX%" exec --skip-git-repo-check %*
  exit /b %ERRORLEVEL%
)
call "%REAL_CODEX%" %*
exit /b %ERRORLEVEL%
