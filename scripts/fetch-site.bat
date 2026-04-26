@echo off
setlocal ENABLEDELAYEDEXPANSION

set "SITE_URL=https://tweaktrak.ibiza.dev/"
set "SITE_DIR=site"
if not "%~1"=="" set "SITE_DIR=%~1"

if exist "%SITE_DIR%.tmp" rmdir /S /Q "%SITE_DIR%.tmp"
mkdir "%SITE_DIR%.tmp"
if not exist "%SITE_DIR%" mkdir "%SITE_DIR%"

where lftp >NUL 2>&1
if %ERRORLEVEL%==0 (
  lftp -e "set ssl:verify-certificate yes; mirror --parallel=8 --verbose / %SITE_DIR%.tmp; bye" %SITE_URL%
  goto :flatten
)

where wget2 >NUL 2>&1
if %ERRORLEVEL%==0 (
  wget2 --mirror --adjust-extension --convert-links --page-requisites --no-host-directories --directory-prefix "%SITE_DIR%.tmp" %SITE_URL%
  goto :flatten
)

echo No supported mirror tool found. Install lftp or wget2.
exit /b 1

:flatten
for /f "delims=" %%F in ('dir /s /b "%SITE_DIR%.tmp\index.html"') do (
  set "INDEX_PATH=%%F"
  goto :gotindex
)

echo Could not locate index.html in mirrored output
exit /b 1

:gotindex
for %%F in ("!INDEX_PATH!") do set "ROOT_DIR=%%~dpF"
robocopy "!ROOT_DIR!" "%SITE_DIR%" /E /NFL /NDL /NJH /NJS /NC /NS >NUL
if not exist "%SITE_DIR%\index.html" (
  echo Flattening failed: %SITE_DIR%\index.html missing
  exit /b 1
)

rmdir /S /Q "%SITE_DIR%.tmp"
echo Site mirror ready at %SITE_DIR%
exit /b 0
