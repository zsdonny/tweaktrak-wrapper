#requires -Version 5.1
<#
.SYNOPSIS
  Runtime smoke gate for the Tauri (WebView2) wrapper on Windows.

.DESCRIPTION
  Launches the smoke-feature build of the Tauri wrapper exe with
  TWEAKTRAK_SMOKE=1 and asserts the JSON report it writes meets the
  pass criteria:

    * the SPA actually mounted (>= SmokeMinDomNodes descendants under
      #root / #app / body)
    * no fatal console messages (any console.error or any pattern in
      $FatalConsolePatterns)
    * no runtime errors (window.onerror, unhandledrejection,
      securitypolicyviolation events)

  Caveat: the Tauri smoke captures console / runtime errors by injecting
  a JS bootstrap on page-load-started. Errors that fire during the very
  first HTML parse — before the bootstrap is evaluated — may be missed.
  The Electron smoke catches that earlier window via Chromium's native
  console-message event and remains the canonical CSP gate; the Tauri
  smoke is supplementary coverage for the Windows binary.

.PARAMETER ExePath
  Path to the smoke-feature exe (built with `cargo build --features smoke`).

.PARAMETER SiteDir
  Path to the mirrored site/ directory the exe resolves at runtime.

.PARAMETER OutputDir
  Directory to write smoke-report.json + smoke-summary.md (created if
  missing). Default: smoke-out-tauri.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $ExePath,
  [Parameter(Mandatory = $true)] [string] $SiteDir,
  [string] $OutputDir = 'smoke-out-tauri',
  [int] $SmokeWaitMs = 8000,
  [int] $SmokeHardTimeoutMs = 60000,
  [int] $SmokeProcessTimeoutSec = 90,
  [int] $SmokeMinDomNodes = 50,
  [string[]] $FatalConsolePatterns = @(
    'Refused to', 'Content Security Policy', 'Uncaught',
    'SyntaxError', 'TypeError', 'ReferenceError'
  )
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ExePath)) {
  throw "smoke-tauri: exe not found at $ExePath"
}
if (-not (Test-Path -LiteralPath (Join-Path $SiteDir 'index.html'))) {
  throw "smoke-tauri: missing index.html in $SiteDir"
}

$null = New-Item -ItemType Directory -Force -Path $OutputDir
$OutputDirAbs = (Resolve-Path -LiteralPath $OutputDir).ProviderPath
$ReportPath = Join-Path $OutputDirAbs 'smoke-report.json'
$SummaryPath = Join-Path $OutputDirAbs 'smoke-summary.md'
$RunLog = Join-Path $OutputDirAbs 'tauri-run.log'
foreach ($p in @($ReportPath, $SummaryPath, $RunLog)) {
  if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}

# tauri::generate_context! reads tauri.conf.json at compile time and
# resolves frontendDist relative to src-tauri/. The exe at runtime
# expects the bundled site at the same relative path, so we must run
# from a working directory where ../site points to the mirrored copy.
$RepoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$ExpectedSite = Join-Path $RepoRoot.ProviderPath 'site'
$SiteDirAbs = (Resolve-Path -LiteralPath $SiteDir).ProviderPath
$LinkCreated = $false
if ($SiteDirAbs -ne $ExpectedSite) {
  if (Test-Path -LiteralPath $ExpectedSite) {
    $existing = Get-Item -LiteralPath $ExpectedSite -Force
    if (-not $existing.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
      throw "smoke-tauri: $ExpectedSite exists and is not a junction; refusing to overwrite."
    }
    Remove-Item -LiteralPath $ExpectedSite -Force -Recurse
  }
  cmd /c mklink /J "`"$ExpectedSite`"" "`"$SiteDirAbs`"" | Out-Null
  $LinkCreated = $true
}

try {
  $env:TWEAKTRAK_SMOKE = '1'
  $env:TWEAKTRAK_SMOKE_REPORT = $ReportPath
  $env:TWEAKTRAK_SMOKE_WAIT_MS = "$SmokeWaitMs"
  $env:TWEAKTRAK_SMOKE_HARD_TIMEOUT_MS = "$SmokeHardTimeoutMs"

  $ExePathAbs = (Resolve-Path -LiteralPath $ExePath).ProviderPath
  Write-Host "smoke-tauri: launching $ExePathAbs"

  $proc = Start-Process -FilePath $ExePathAbs `
    -WorkingDirectory $RepoRoot.ProviderPath `
    -RedirectStandardOutput $RunLog `
    -RedirectStandardError "$RunLog.err" `
    -PassThru -WindowStyle Hidden

  $deadline = (Get-Date).AddSeconds($SmokeProcessTimeoutSec)
  while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
  }

  if (-not $proc.HasExited) {
    Write-Warning "smoke-tauri: process did not exit within ${SmokeProcessTimeoutSec}s; terminating."
    try { $proc.Kill($true) } catch { try { $proc.Kill() } catch { } }
    Start-Sleep -Seconds 2
  }

  if (Test-Path -LiteralPath "$RunLog.err") {
    Get-Content -LiteralPath "$RunLog.err" | Add-Content -LiteralPath $RunLog
    Remove-Item -LiteralPath "$RunLog.err" -Force
  }
}
finally {
  if ($LinkCreated -and (Test-Path -LiteralPath $ExpectedSite)) {
    cmd /c rmdir "`"$ExpectedSite`"" | Out-Null
  }
  Remove-Item Env:\TWEAKTRAK_SMOKE -ErrorAction SilentlyContinue
  Remove-Item Env:\TWEAKTRAK_SMOKE_REPORT -ErrorAction SilentlyContinue
  Remove-Item Env:\TWEAKTRAK_SMOKE_WAIT_MS -ErrorAction SilentlyContinue
  Remove-Item Env:\TWEAKTRAK_SMOKE_HARD_TIMEOUT_MS -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $ReportPath)) {
  Write-Error "smoke-tauri: report not produced. Last 50 log lines:"
  if (Test-Path -LiteralPath $RunLog) { Get-Content -LiteralPath $RunLog -Tail 50 | Write-Host }
  exit 1
}

$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json

$failures = New-Object System.Collections.Generic.List[string]
$summary = New-Object System.Collections.Generic.List[string]
$summary.Add('# Tauri smoke gate')
$summary.Add('')
$summary.Add(("- exitReason: ``" + ($report.exitReason) + "``"))
$summary.Add(("- href: ``" + ($report.href) + "``"))

# DOM probe
$probe = $report.domProbe
if ($null -ne $probe) {
  $desc = [int]$probe.descendantCount
  $summary.Add(("- DOM probe: root=``" + $probe.rootId + "`` descendants=``" + $desc +
                "`` bodyText=``" + $probe.bodyTextLength + "`` chars"))
  if ($desc -lt $SmokeMinDomNodes) {
    $failures.Add("SPA mount probe failed: only $desc descendants under root (threshold $SmokeMinDomNodes)")
  }
} else {
  $failures.Add('DOM probe never ran (likely hard-timeout before settle)')
}

# Console messages
$console = @($report.consoleMessages)
$fatalRegex = ($FatalConsolePatterns -join '|')
$fatalConsole = New-Object System.Collections.Generic.List[object]
foreach ($m in $console) {
  $isError = ($m.level -eq 'error') -or ($m.message -match $fatalRegex)
  if ($isError) { $fatalConsole.Add($m) }
}
$summary.Add(("- console messages: ``" + $console.Count + "`` (fatal: ``" + $fatalConsole.Count + "``)"))
if ($fatalConsole.Count -gt 0) {
  $summary.Add('')
  $summary.Add('<details><summary>Fatal console messages</summary>')
  $summary.Add('')
  foreach ($m in $fatalConsole | Select-Object -First 50) {
    $snippet = ($m.message -replace '`', "'")
    if ($snippet.Length -gt 240) { $snippet = $snippet.Substring(0, 240) }
    $summary.Add(("- " + $m.level + ": ``" + $snippet + "``"))
  }
  $summary.Add('</details>')
  $failures.Add(("$($fatalConsole.Count) fatal console message(s)"))
}

# Runtime errors
$errs = @($report.runtimeErrors)
$summary.Add(("- runtime errors: ``" + $errs.Count + "``"))
if ($errs.Count -gt 0) {
  $summary.Add('')
  $summary.Add('<details><summary>Runtime errors</summary>')
  $summary.Add('')
  foreach ($e in $errs | Select-Object -First 50) {
    $snippet = ($e.message -replace '`', "'")
    if ($snippet.Length -gt 240) { $snippet = $snippet.Substring(0, 240) }
    $summary.Add(("- " + $e.kind + ": ``" + $snippet + "``"))
  }
  $summary.Add('</details>')
  $failures.Add(("$($errs.Count) runtime error(s)"))
}

$summary.Add('')
if ($failures.Count -eq 0) {
  $summary.Add('**Result: ✅ passed**')
} else {
  $summary.Add('**Result: ❌ failed**')
  $summary.Add('')
  foreach ($f in $failures) { $summary.Add("- $f") }
}

$summaryText = ($summary -join "`n") + "`n"
Set-Content -LiteralPath $SummaryPath -Value $summaryText -Encoding UTF8
Write-Host $summaryText

if ($env:GITHUB_STEP_SUMMARY) {
  Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summaryText
}
if ($env:GITHUB_OUTPUT) {
  if ($failures.Count -eq 0) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value 'smoke_passed=true'
  } else {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value 'smoke_passed=false'
  }
}

if ($failures.Count -gt 0) { exit 1 }
Write-Host "smoke-tauri: passed (report at $ReportPath)"
