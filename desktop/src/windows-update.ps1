param([Parameter(Mandatory=$true)][string]$Plan, [switch]$Prepare, [switch]$Launch)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$p = Get-Content -LiteralPath $Plan -Raw -Encoding UTF8 | ConvertFrom-Json
if ($Launch) {
  # A detached Node spawn can make Windows PowerShell exit before -File runs.
  # Start through a normal short-lived PowerShell launcher instead. Its native
  # child has its own hidden window and file-backed output, and survives both
  # this launcher and the application. Arguments are native argv, not shell code.
  if ($PSCommandPath -match '["\r\n]' -or $Plan -match '["\r\n]') { throw 'Invalid installer location' }
  $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Plan "' + $Plan + '"'
  $child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -WorkingDirectory ([IO.Path]::GetDirectoryName($p.result)) -WindowStyle Hidden -RedirectStandardOutput $p.stdoutLog -RedirectStandardError $p.stderrLog -PassThru
  exit 0
}
function Get-SHA256([string]$File) {
  # Windows PowerShell launched from a newer shell can inherit a module path
  # without Get-FileHash. Use the built-in .NET primitive on both runtimes.
  $stream = [IO.File]::OpenRead($File)
  $algorithm = [Security.Cryptography.SHA256]::Create()
  try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
  finally { $algorithm.Dispose(); $stream.Dispose() }
}
function Assert-Package {
  $f = Get-Item -LiteralPath $p.file
  if (($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $f.Length -ne $p.size -or (Get-SHA256 $p.file) -ne $p.sha256) { throw 'Update package verification failed' }
}
function Assert-PlainTree([string]$Root) {
  $items = @(Get-Item -LiteralPath $Root) + @(Get-ChildItem -LiteralPath $Root -Recurse -Force)
  foreach ($item in $items) { if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Application folder contains a link' } }
}
function Assert-ApplicationFolder([string]$Root) {
  Assert-PlainTree $Root
  if (!(Test-Path -LiteralPath (Join-Path $Root 'TheAll.exe')) -or !(Test-Path -LiteralPath (Join-Path $Root 'resources\app.asar'))) { throw 'Not a TheAll application folder' }
  # ZIP replacement is only safe in a dedicated application directory. Preserve
  # user-created files by refusing a mixed directory instead of deleting them.
  foreach ($item in Get-ChildItem -LiteralPath $Root -Force) {
    if ($item.Name -notmatch '^(TheAll\.exe|chrome_[0-9]+_percent\.pak|d3dcompiler_47\.dll|dxcompiler\.dll|dxil\.dll|electron_wer\.dll|ffmpeg\.dll|icudtl\.dat|libEGL\.dll|libGLESv2\.dll|LICENSE|LICENSES\.chromium\.html|LICENSE\.electron\.txt|locales|resources|resources\.pak|snapshot_blob\.bin|v8_context_snapshot\.bin|vk_swiftshader\.dll|vk_swiftshader_icd\.json|vulkan-1\.dll|swiftshader|version)$') { throw 'Move the ZIP build into its own application folder before updating' }
  }
}
function Assert-Staged {
  if ((Get-SHA256 $p.manifest) -ne $p.manifestHash) { throw 'Prepared update manifest changed' }
  Assert-ApplicationFolder $p.stage
  $files = @(Get-ChildItem -LiteralPath $p.stage -File -Recurse -Force)
  # Windows PowerShell 5.1 emits a JSON array as one pipeline object. Assign
  # before wrapping so the manifest remains an array of file records on 5.1/7.
  $manifest = Get-Content -LiteralPath $p.manifest -Raw -Encoding UTF8 | ConvertFrom-Json
  $manifest = @($manifest)
  if ($files.Count -ne $manifest.Count) { throw 'Prepared update files changed' }
  foreach ($record in $manifest) {
    $file = Join-Path $p.stage $record.name
    $item = Get-Item -LiteralPath $file
    if ($item.Length -ne $record.size -or (Get-SHA256 $file) -ne $record.sha256) { throw 'Prepared update files changed' }
  }
}
function Get-ManifestRecords([string]$Root, [string]$Prefix = '') {
  # Windows TEMP can use an 8.3 path while FileInfo expands its ancestors.
  # Build relative names from directory entries, never by trimming that path.
  foreach ($item in Get-ChildItem -LiteralPath $Root -Force) {
    $name = if ($Prefix) { $Prefix + '\' + $item.Name } else { $item.Name }
    if ($item.PSIsContainer) { Get-ManifestRecords $item.FullName $name }
    else { @{ name=$name; size=$item.Length; sha256=(Get-SHA256 $item.FullName) } }
  }
}
Assert-Package
if ($Prepare) {
  if ($p.kind -eq 'zip') {
    Assert-ApplicationFolder $p.target
    [IO.Directory]::CreateDirectory($p.stage) | Out-Null
    $archive = [IO.Compression.ZipFile]::OpenRead($p.file)
    try {
      if ($archive.Entries.Count -gt 20000) { throw 'Too many update archive entries' }
      $total = [long]0
      foreach ($entry in $archive.Entries) {
        $name = $entry.FullName.Replace('\','/'); $parts = $name.TrimEnd('/').Split('/')
        $invalidParts = @($parts | Where-Object { $_ -in @('','.','..') -or $_ -match '[. ]$|^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)' })
        if (!$name -or $name.StartsWith('/') -or $name -match '[:\x00-\x1f]' -or $invalidParts.Count -gt 0) { throw 'Unsafe update archive path' }
        if ((($entry.ExternalAttributes -shr 16) -band 61440) -eq 40960 -or ($entry.ExternalAttributes -band 1024)) { throw 'Update archive contains links' }
        $total += $entry.Length
        if ($total -gt 3221225472) { throw 'Expanded update is too large' }
        $dest = Join-Path $p.stage ($name.Replace('/','\'))
        if ($name.EndsWith('/')) { [IO.Directory]::CreateDirectory($dest) | Out-Null; continue }
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest)) | Out-Null
        $output = [IO.File]::Open($dest, [IO.FileMode]::CreateNew)
        $inputStream = $entry.Open()
        try { $inputStream.CopyTo($output) } finally { $inputStream.Dispose(); $output.Dispose() }
      }
    } finally { $archive.Dispose() }
    Assert-ApplicationFolder $p.stage
    $manifest = @(Get-ManifestRecords $p.stage)
    ConvertTo-Json -InputObject $manifest -Depth 3 -Compress | Set-Content -LiteralPath $p.manifest -Encoding UTF8
  }
  exit 0
}
# Spawned before shutdown; nothing can be changed until the parent has saved
# drafts and committed the one-time handoff marker.
[IO.File]::WriteAllText($p.ready, 'ready')
function Test-Cancelled {
  # A failed application save removes this update's cache after cancellation.
  # Treat a missing plan as cancellation too; never relaunch after normal quit.
  return (Test-Path -LiteralPath $p.cancel) -or !(Test-Path -LiteralPath $Plan -PathType Leaf)
}
$deadline = [DateTime]::UtcNow.AddSeconds(120)
while (!(Test-Path -LiteralPath $p.go)) {
  if ((Test-Cancelled) -or [DateTime]::UtcNow -gt $deadline) { exit 1 }
  Start-Sleep -Milliseconds 100
}
try {
  $process = Get-Process -Id $p.pid -ErrorAction SilentlyContinue
  $deadline = [DateTime]::UtcNow.AddSeconds(60)
  while ($process -and !$process.WaitForExit(100)) {
    if (Test-Cancelled) { exit 1 }
    if ([DateTime]::UtcNow -gt $deadline) { throw 'TheAll did not exit; update cancelled' }
  }
  if (Test-Cancelled) { exit 1 }
  Assert-Package
  if ($p.kind -eq 'nsis') {
    $arguments = '/S --updated --force-run /D=' + $p.target
    $installer = Start-Process -FilePath $p.file -ArgumentList $arguments -PassThru -Wait
    if ($installer.ExitCode -ne 0) { throw "Installer failed ($($installer.ExitCode))" }
  } else {
    if ($p.kind -eq 'zip') { Assert-Staged; Assert-ApplicationFolder $p.target }
    else {
      Copy-Item -LiteralPath $p.file -Destination $p.stage
      if ((Get-SHA256 $p.stage) -ne $p.sha256) { throw 'Prepared executable changed' }
    }
    # Rename on the same volume, keeping the original until replacement works.
    # Portable launchers can briefly hold their outer executable after Electron exits.
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while ($true) {
      try { Move-Item -LiteralPath $p.target -Destination $p.backup; break }
      catch { if ([DateTime]::UtcNow -gt $deadline) { throw }; Start-Sleep -Milliseconds 250 }
    }
    try {
      Move-Item -LiteralPath $p.stage -Destination $p.target
      $exe = if ($p.kind -eq 'zip') { Join-Path $p.target 'TheAll.exe' } else { $p.target }
      Start-Process -FilePath $exe -WorkingDirectory ([IO.Path]::GetDirectoryName($exe)) -ErrorAction Stop | Out-Null
    } catch {
      if (Test-Path -LiteralPath $p.target) { Move-Item -LiteralPath $p.target -Destination $p.stage }
      Move-Item -LiteralPath $p.backup -Destination $p.target
      throw
    }
  }
  [IO.File]::WriteAllText($p.result, '{"ok":true}')
} catch {
  [IO.File]::WriteAllText($p.result, (@{ok=$false; error=$_.Exception.Message} | ConvertTo-Json -Compress))
  # Keep the original install and backup available. A normal relaunch displays
  # this result and allows a retry without touching any profile files.
  $exe = if ($p.kind -eq 'portable') { $p.target } else { Join-Path $p.target 'TheAll.exe' }
  if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe -ErrorAction SilentlyContinue | Out-Null }
  exit 1
}
