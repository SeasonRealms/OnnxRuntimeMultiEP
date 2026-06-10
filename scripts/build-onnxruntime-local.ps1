[CmdletBinding()]
param(
  [string]$OrtRef = "v1.26.0",
  [string]$CudaVersion = "12.8.1",
  [string]$CudnnVersion = "9.8.0.87",
  [string]$CudaArchitectures = "70-real;75-real;80-real;86-real;89-real;90-virtual",
  [ValidateSet("Auto", "Insiders", "Stable")][string]$VisualStudioChannel = "Insiders",
  [int]$ParallelJobs = 2,
  [int]$NvccThreads = 1,
  [string]$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
  [string]$WorkRoot = (Join-Path $PSScriptRoot ".ort-local"),
  [string]$LocalOrtSourceDir = (Join-Path $PSScriptRoot "onnxruntime-1.26.0"),
  [switch]$ForceReinstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$script:ManifestPath = Join-Path $WorkRoot "install-manifest.json"
$script:InstallManifest = [ordered]@{
  schema_version = 1
  workspace_root = $WorkspaceRoot
  work_root = $WorkRoot
  ort_ref = $OrtRef
  cuda_version = $CudaVersion
  cudnn_version = $CudnnVersion
  cuda_architectures = $CudaArchitectures
  visual_studio_channel = $VisualStudioChannel
  parallel_jobs = $ParallelJobs
  nvcc_threads = $NvccThreads
  winget_packages = @()
  paths = [ordered]@{}
  state = [ordered]@{
    build_completed = $false
  }
  updated_at = (Get-Date).ToString("s")
}

function Write-Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-DebugPoint {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [hashtable]$Data = @{}
  )

  $payload = [ordered]@{
    id = $Id
    time = (Get-Date).ToString("s")
    data = $Data
  }
  Write-Host ("[debug] " + ($payload | ConvertTo-Json -Compress -Depth 5)) -ForegroundColor DarkGray
}

function Save-InstallManifest {
  Ensure-Directory -Path $WorkRoot
  $script:InstallManifest.updated_at = (Get-Date).ToString("s")
  $manifestJson = $script:InstallManifest | ConvertTo-Json -Depth 6
  Write-TextFile -Path $script:ManifestPath -Value $manifestJson -Encoding ASCII
}

function Add-ManifestWingetPackage {
  param([Parameter(Mandatory = $true)][string]$PackageId)

  if (-not ($script:InstallManifest.winget_packages -contains $PackageId)) {
    $script:InstallManifest.winget_packages += $PackageId
    Save-InstallManifest
  }
}

function Set-ManifestPathValue {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [AllowNull()][string]$Value
  )

  $script:InstallManifest.paths[$Name] = $Value
  Save-InstallManifest
}

function Set-ManifestStateValue {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    $Value
  )

  $script:InstallManifest.state[$Name] = $Value
  Save-InstallManifest
}

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  #region debug-point admin-check
  Write-DebugPoint -Id "admin-check" -Data @{
    user = $identity.Name
    is_admin = $isAdmin
  }
  #endregion
  return $isAdmin
}

function Assert-Administrator {
  param([string]$Reason = "unspecified")

  if (-not (Test-IsAdministrator)) {
    #region debug-point admin-required
    Write-DebugPoint -Id "admin-required" -Data @{
      reason = $Reason
      work_root = $WorkRoot
    }
    #endregion
    throw "Administrator privileges are required for: $Reason. Please rerun this script from an elevated PowerShell window."
  }
}

function Test-CommandExists {
  param([string]$CommandName)
  return $null -ne (Get-Command $CommandName -ErrorAction SilentlyContinue)
}

function Invoke-External {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [string]$WorkingDirectory
  )

  if ($WorkingDirectory) {
    $resolvedWorkingDirectory = (Resolve-Path $WorkingDirectory).Path
  } else {
    $resolvedWorkingDirectory = (Get-Location).Path
  }

  Write-Host "$FilePath $($ArgumentList -join ' ')"
  $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru -NoNewWindow -WorkingDirectory $resolvedWorkingDirectory
  if ($process.ExitCode -ne 0) {
    throw "Command failed with exit code $($process.ExitCode): $FilePath"
  }
}

function Invoke-WingetInstall {
  param(
    [Parameter(Mandatory = $true)][string]$PackageId,
    [string]$Version,
    [string]$OverrideArguments
  )

  if (-not (Test-CommandExists "winget.exe")) {
    throw "winget.exe is required but was not found. Install App Installer first."
  }

  $arguments = @(
    "install",
    "--id", $PackageId,
    "--exact",
    "--source", "winget",
    "--silent",
    "--accept-package-agreements",
    "--accept-source-agreements",
    "--disable-interactivity"
  )

  if ($Version) {
    $arguments += @("--version", $Version)
  }

  if ($OverrideArguments) {
    $arguments += @("--override", $OverrideArguments)
  }

  $displayArguments = foreach ($argument in $arguments) {
    if ($argument -match '\s') {
      '"' + $argument + '"'
    } else {
      $argument
    }
  }

  Write-Host "winget.exe $($displayArguments -join ' ')"
  & winget.exe @arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed with exit code ${LASTEXITCODE}: winget.exe"
  }
}

function Ensure-Directory {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Write-TextFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Value,
    [ValidateSet("ASCII", "UTF8")][string]$Encoding = "UTF8"
  )

  $parent = Split-Path -Parent $Path
  if ($parent) {
    Ensure-Directory -Path $parent
  }

  $textEncoding = switch ($Encoding) {
    "ASCII" { [System.Text.Encoding]::ASCII }
    default { New-Object System.Text.UTF8Encoding($false) }
  }

  [System.IO.File]::WriteAllText($Path, $Value, $textEncoding)
}

function Copy-DirectoryContents {
  param(
    [Parameter(Mandatory = $true)][string]$SourceDirectory,
    [Parameter(Mandatory = $true)][string]$DestinationDirectory
  )

  if (-not (Test-Path $SourceDirectory)) {
    return
  }

  Ensure-Directory -Path $DestinationDirectory
  $resolvedSource = (Resolve-Path $SourceDirectory).Path
  $resolvedDestination = (Resolve-Path $DestinationDirectory).Path

  $sourceRootWithSeparator = $resolvedSource.TrimEnd('\') + '\'
  foreach ($item in (Get-ChildItem -Path $resolvedSource -Recurse -File)) {
    $relativePath = $item.FullName.Substring($sourceRootWithSeparator.Length)
    $targetPath = Join-Path $resolvedDestination $relativePath
    $targetParent = Split-Path -Parent $targetPath
    if ($targetParent) {
      Ensure-Directory -Path $targetParent
    }
    [System.IO.File]::Copy($item.FullName, $targetPath, $true)
  }
}

function Copy-FileToDirectory {
  param(
    [Parameter(Mandatory = $true)][string]$SourceFile,
    [Parameter(Mandatory = $true)][string]$DestinationDirectory
  )

  Ensure-Directory -Path $DestinationDirectory
  $targetPath = Join-Path $DestinationDirectory ([System.IO.Path]::GetFileName($SourceFile))
  [System.IO.File]::Copy($SourceFile, $targetPath, $true)
}

function Remove-DirectoryTree {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (Test-Path $Path) {
    [System.IO.Directory]::Delete($Path, $true)
  }
}

function Get-PythonCommand {
  if (Test-CommandExists "py.exe") {
    & py -3.11 -c "import sys; print(sys.executable)" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
      return @("py", "-3.11")
    }
  }

  if (Test-CommandExists "python.exe") {
    $pythonVersion = (& python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null)
    if ($LASTEXITCODE -eq 0 -and $pythonVersion -eq "3.11") {
      return @("python")
    }
  }

  return $null
}

function Invoke-Python {
  param(
    [Parameter(Mandatory = $true)][string[]]$PythonCommand,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  if ($PythonCommand.Count -eq 1) {
    & $PythonCommand[0] @Arguments
  } else {
    $prefix = @()
    if ($PythonCommand.Count -gt 1) {
      $prefix = $PythonCommand[1..($PythonCommand.Count - 1)]
    }
    & $PythonCommand[0] @prefix @Arguments
  }
}

function Ensure-Python311 {
  Write-Step "Ensuring Python 3.11"
  $pythonCommand = Get-PythonCommand
  if ($null -eq $pythonCommand) {
    Invoke-WingetInstall -PackageId "Python.Python.3.11"
    Add-ManifestWingetPackage -PackageId "Python.Python.3.11"
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $pythonCommand = Get-PythonCommand
    if ($null -eq $pythonCommand) {
      throw "Python 3.11 installation finished but the interpreter is still not discoverable."
    }
  }

  Invoke-Python -PythonCommand $pythonCommand -Arguments @("-m", "pip", "install", "--upgrade", "pip")
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to upgrade pip."
  }

  Invoke-Python -PythonCommand $pythonCommand -Arguments @("-m", "pip", "install", "ninja", "psutil", "packaging", "setuptools", "wheel")
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to install Python build dependencies."
  }

  return $pythonCommand
}

function Ensure-Git {
  Write-Step "Ensuring Git"
  if (-not (Test-CommandExists "git.exe")) {
    Invoke-WingetInstall -PackageId "Git.Git"
    Add-ManifestWingetPackage -PackageId "Git.Git"
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
  }

  if (-not (Test-CommandExists "git.exe")) {
    throw "Git installation finished but git.exe is still not discoverable."
  }
}

function Ensure-CMake {
  Write-Step "Ensuring CMake"
  if (-not (Test-CommandExists "cmake.exe")) {
    Invoke-WingetInstall -PackageId "Kitware.CMake"
    Add-ManifestWingetPackage -PackageId "Kitware.CMake"
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
  }

  if (-not (Test-CommandExists "cmake.exe")) {
    throw "CMake installation finished but cmake.exe is still not discoverable."
  }
}

function Get-VSWherePath {
  $candidates = @(
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe",
    "$env:ProgramFiles\Microsoft Visual Studio\Installer\vswhere.exe"
  )

  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) {
      return $candidate
    }
  }

  return $null
}

function Test-IsPreviewVcvarsPath {
  param([AllowNull()][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $false
  }

  return $Path -match '\\(Insiders|Preview|IntPreview|Dogfood)\\'
}

function Get-VCVarsPath {
  param(
    [ValidateSet("Auto", "Insiders", "Stable")][string]$ChannelPreference = "Auto"
  )

  $vswhere = Get-VSWherePath
  if (-not $vswhere) {
    return $null
  }

  $queryPlans = switch ($ChannelPreference) {
    "Insiders" { @(@("-latest", "-prerelease")) }
    "Stable" { @(@("-latest")) }
    default { @(@("-latest", "-prerelease"), @("-latest")) }
  }

  foreach ($queryPlan in $queryPlans) {
    $arguments = @()
    $arguments += $queryPlan
    $arguments += @(
      "-products", "*",
      "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
      "-find", "VC\Auxiliary\Build\vcvars64.bat"
    )

    $vcvarsOutput = & $vswhere @arguments
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($vcvarsOutput)) {
      $candidates = @($vcvarsOutput -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      foreach ($candidate in $candidates) {
        if ($ChannelPreference -eq "Insiders" -and -not (Test-IsPreviewVcvarsPath -Path $candidate)) {
          continue
        }
        if ($ChannelPreference -eq "Stable" -and (Test-IsPreviewVcvarsPath -Path $candidate)) {
          continue
        }
        return $candidate
      }
    }
  }

  $fallbackPath = Get-VCVarsPathFromKnownLocations -ChannelPreference $ChannelPreference
  if ($fallbackPath) {
    return $fallbackPath
  }

  return $null
}

function Resolve-OrtBuildVCVarsPath {
  param([Parameter(Mandatory = $true)][string]$PreferredPath)

  if (-not (Test-IsPreviewVcvarsPath -Path $PreferredPath)) {
    return $PreferredPath
  }

  $stablePath = Get-VCVarsPath -ChannelPreference "Stable"
  if ($stablePath -and -not (Test-IsPreviewVcvarsPath -Path $stablePath)) {
    #region debug-point cuda-vs-fallback
    Write-DebugPoint -Id "cuda-vs-fallback" -Data @{
      preferred_vcvars = $PreferredPath
      selected_vcvars = $stablePath
      reason = "nvcc-does-not-support-vs-insiders"
      cuda_version = $CudaVersion
    }
    #endregion
    Write-Warning "CUDA build is falling back to the stable Visual Studio C++ toolchain because NVCC does not support Visual Studio Insiders yet."
    return $stablePath
  }

  return $PreferredPath
}

function Get-VCVarsPathFromKnownLocations {
  param(
    [ValidateSet("Auto", "Insiders", "Stable")][string]$ChannelPreference = "Auto"
  )

  $roots = @(
    "$env:ProgramFiles\Microsoft Visual Studio",
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio"
  ) | Where-Object { $_ -and (Test-Path $_) }

  $allCandidates = @()
  foreach ($root in $roots) {
    $pattern = Join-Path $root "*\*\VC\Auxiliary\Build\vcvars64.bat"
    $allCandidates += @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue)
  }

  if ($allCandidates.Count -eq 0) {
    return $null
  }

  $previewCandidates = @($allCandidates | Where-Object { Test-IsPreviewVcvarsPath -Path $_.FullName } | Sort-Object FullName -Descending)
  $stableCandidates = @($allCandidates | Where-Object { -not (Test-IsPreviewVcvarsPath -Path $_.FullName) } | Sort-Object FullName -Descending)

  $selectedCandidates = switch ($ChannelPreference) {
    "Insiders" { $previewCandidates }
    "Stable" { $stableCandidates }
    default { @($previewCandidates + $stableCandidates) }
  }

  foreach ($candidate in $selectedCandidates) {
    if (Test-Path $candidate.FullName) {
      return $candidate.FullName
    }
  }

  return $null
}

function Ensure-VSBuildTools {
  Write-Step "Ensuring Visual Studio C++ toolchain"
  if ($VisualStudioChannel -eq "Insiders") {
    Write-Host "Preferring the local Visual Studio 2026 Insiders C++ toolchain."
  }
  $vcvarsPath = Get-VCVarsPath -ChannelPreference $VisualStudioChannel
  if ($vcvarsPath) {
    Write-Host "Using Visual Studio toolchain from: $vcvarsPath"
    $sourceLabel = if ($VisualStudioChannel -eq "Insiders") { "installed_insiders" } else { "installed" }
    Set-ManifestStateValue -Name "visual_studio_source" -Value $sourceLabel
    return $vcvarsPath
  }

  if ($VisualStudioChannel -eq "Insiders") {
    throw "Visual Studio Insiders with C++ build tools was not found. Install the Desktop development with C++ workload in VS 2026 Insiders, or rerun with -VisualStudioChannel Auto/Stable."
  }

  #region debug-point vs-buildtools-install-required
  Write-DebugPoint -Id "vs-buildtools-install-required" -Data @{
    channel = $VisualStudioChannel
  }
  #endregion
  Assert-Administrator -Reason "installing Visual Studio Build Tools"
  $override = "--wait --quiet --norestart --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --includeRecommended --addProductLang En-us"
  Invoke-WingetInstall -PackageId "Microsoft.VisualStudio.2022.BuildTools" -OverrideArguments $override
  Add-ManifestWingetPackage -PackageId "Microsoft.VisualStudio.2022.BuildTools"

  $vcvarsPath = Get-VCVarsPath -ChannelPreference "Stable"
  if (-not $vcvarsPath) {
    throw "Visual Studio toolchain is still not discoverable after installation. Checked both vswhere and common Visual Studio install paths under Program Files. If you already have VS 2026 Insiders, rerun with -VisualStudioChannel Insiders after updating to the latest script copy."
  }

  Set-ManifestStateValue -Name "visual_studio_source" -Value "winget_buildtools_2022"
  return $vcvarsPath
}

function Get-CudaInstallRoot {
  param([Parameter(Mandatory = $true)][string]$Version)
  $majorMinor = ($Version -split '\.')[0..1] -join "."
  return "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v$majorMinor"
}

function Get-CudaNvccVersion {
  param([Parameter(Mandatory = $true)][string]$CudaRoot)
  $nvccPath = Join-Path $CudaRoot "bin\nvcc.exe"
  if (-not (Test-Path $nvccPath)) {
    return $null
  }

  $versionText = & $nvccPath --version 2>$null | Out-String
  if ($versionText -match 'release\s+(\d+\.\d+)') {
    return $Matches[1]
  }

  return $null
}

function Ensure-CudaToolkit {
  param([Parameter(Mandatory = $true)][string]$Version)

  Write-Step "Ensuring CUDA Toolkit $Version"

  $cudaRoot = Get-CudaInstallRoot -Version $Version
  $requestedSeries = ($Version -split '\.')[0..1] -join "."
  $installedSeries = Get-CudaNvccVersion -CudaRoot $cudaRoot

  if (-not $ForceReinstall -and $installedSeries -eq $requestedSeries) {
    Write-Host "CUDA $requestedSeries already available at $cudaRoot"
    Set-ManifestPathValue -Name "cuda_root" -Value $cudaRoot
    Set-ManifestStateValue -Name "cuda_installed_by_script" -Value $false
    return $cudaRoot
  }

  $installerUrlMap = @{
    "12.8.1" = "https://developer.download.nvidia.com/compute/cuda/12.8.1/local_installers/cuda_12.8.1_572.61_windows.exe"
  }

  if (-not $installerUrlMap.ContainsKey($Version)) {
    throw "No CUDA installer URL is configured for version $Version. Extend the installer map in this script."
  }

  #region debug-point cuda-install-required
  Write-DebugPoint -Id "cuda-install-required" -Data @{
    version = $Version
    cuda_root = $cudaRoot
  }
  #endregion
  Assert-Administrator -Reason "installing CUDA Toolkit"
  $downloadDir = Join-Path $WorkRoot "downloads"
  Ensure-Directory -Path $downloadDir
  $installerPath = Join-Path $downloadDir ("cuda_{0}_windows.exe" -f $Version)

  if (-not (Test-Path $installerPath)) {
    Write-Host "Downloading CUDA installer from $($installerUrlMap[$Version])"
    Invoke-WebRequest -Uri $installerUrlMap[$Version] -OutFile $installerPath
  }

  Invoke-External -FilePath $installerPath -ArgumentList @("-s", "-n")

  $installedSeries = Get-CudaNvccVersion -CudaRoot $cudaRoot
  if ($installedSeries -ne $requestedSeries) {
    throw "CUDA installation verification failed. Expected series $requestedSeries, got '$installedSeries'."
  }

  Set-ManifestPathValue -Name "cuda_root" -Value $cudaRoot
  Set-ManifestStateValue -Name "cuda_installed_by_script" -Value $true
  return $cudaRoot
}

function Get-CudnnInstallRoot {
  param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$CudaVersion
  )

  $cudaMajor = ($CudaVersion -split '\.')[0]
  return "C:\Program Files\NVIDIA\CUDNN\v$Version-cuda$cudaMajor"
}

function Test-CudnnVersionMatch {
  param(
    [AllowNull()][string]$DetectedVersion,
    [Parameter(Mandatory = $true)][string]$RequestedVersion
  )

  if ([string]::IsNullOrWhiteSpace($DetectedVersion)) {
    return $false
  }

  if ($DetectedVersion -eq $RequestedVersion) {
    return $true
  }

  $requestedParts = $RequestedVersion -split '\.'
  if ($requestedParts.Count -ge 3) {
    $requestedPrefix = ($requestedParts[0..2] -join '.')
    if ($DetectedVersion -eq $requestedPrefix) {
      return $true
    }
  }

  $requestedMajorMinor = if ($requestedParts.Count -ge 2) { $requestedParts[0..1] -join '.' } else { $RequestedVersion }
  return $DetectedVersion -eq $requestedMajorMinor
}

function Get-CudnnVersionFromHeader {
  param([Parameter(Mandatory = $true)][string]$HeaderPath)

  if (-not (Test-Path $HeaderPath)) {
    return $null
  }

  $headerText = Get-Content $HeaderPath -Raw
  $majorMatch = [regex]::Match($headerText, '#define\s+CUDNN_MAJOR\s+(\d+)')
  $minorMatch = [regex]::Match($headerText, '#define\s+CUDNN_MINOR\s+(\d+)')
  $patchMatch = [regex]::Match($headerText, '#define\s+CUDNN_PATCHLEVEL\s+(\d+)')
  if ($majorMatch.Success -and $minorMatch.Success -and $patchMatch.Success) {
    return "$($majorMatch.Groups[1].Value).$($minorMatch.Groups[1].Value).$($patchMatch.Groups[1].Value)"
  }

  return $null
}

function Get-CudnnModernInstallRoot {
  param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$CudaVersion
  )

  $versionParts = $Version -split '\.'
  $majorMinor = if ($versionParts.Count -ge 2) { $versionParts[0..1] -join '.' } else { $Version }
  $cudaSeries = (($CudaVersion -split '\.')[0..1] -join '.')
  $candidateRoot = "C:\Program Files\NVIDIA\CUDNN\v$majorMinor"
  $headerPath = Join-Path $candidateRoot "include\$cudaSeries\cudnn_version.h"
  $binPath = Join-Path $candidateRoot "bin\$cudaSeries"
  $libPath = Join-Path $candidateRoot "lib\$cudaSeries\x64"

  if ((Test-Path $candidateRoot) -and (Test-Path $headerPath) -and (Test-Path $binPath) -and (Test-Path $libPath)) {
    $detectedVersion = Get-CudnnVersionFromHeader -HeaderPath $headerPath
    if (Test-CudnnVersionMatch -DetectedVersion $detectedVersion -RequestedVersion $Version) {
      return $candidateRoot
    }
  }

  return $null
}

function New-CudnnCompatRootFromModernInstall {
  param(
    [Parameter(Mandatory = $true)][string]$InstalledRoot,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$CudaVersion
  )

  $cudaMajor = ($CudaVersion -split '\.')[0]
  $cudaSeries = (($CudaVersion -split '\.')[0..1] -join '.')
  $compatRoot = Join-Path $WorkRoot ("cudnn\v{0}-cuda{1}" -f $Version, $cudaMajor)
  $compatBin = Join-Path $compatRoot "bin"
  $compatInclude = Join-Path $compatRoot "include"
  $compatLib = Join-Path $compatRoot "lib"
  $compatLibX64 = Join-Path $compatRoot "lib\x64"

  Ensure-Directory -Path $compatRoot
  Ensure-Directory -Path $compatBin
  Ensure-Directory -Path $compatInclude
  Ensure-Directory -Path $compatLib
  Ensure-Directory -Path $compatLibX64

  Copy-DirectoryContents -SourceDirectory (Join-Path $InstalledRoot "bin\$cudaSeries") -DestinationDirectory $compatBin
  Copy-DirectoryContents -SourceDirectory (Join-Path $InstalledRoot "include\$cudaSeries") -DestinationDirectory $compatInclude
  Copy-DirectoryContents -SourceDirectory (Join-Path $InstalledRoot "lib\$cudaSeries\x64") -DestinationDirectory $compatLibX64

  $manifest = [ordered]@{
    cudnn_version = $Version
    cuda_major = $cudaMajor
    installed_from = $InstalledRoot
    installed_layout = "modern"
    installed_at = (Get-Date).ToString("s")
  }
  $manifestJson = $manifest | ConvertTo-Json -Depth 3
  Write-TextFile -Path (Join-Path $compatRoot "seasonengine-cudnn-install.json") -Value $manifestJson -Encoding ASCII

  return $compatRoot
}

function Get-CudnnInstalledVersion {
  param([Parameter(Mandatory = $true)][string]$CudnnRoot)

  $manifestPath = Join-Path $CudnnRoot "seasonengine-cudnn-install.json"
  if (Test-Path $manifestPath) {
    return (Get-Content $manifestPath -Raw | ConvertFrom-Json).cudnn_version
  }

  $versionHeader = Join-Path $CudnnRoot "include\cudnn_version.h"
  if (-not (Test-Path $versionHeader)) {
    return $null
  }

  return (Get-CudnnVersionFromHeader -HeaderPath $versionHeader)
}

function Ensure-Cudnn {
  param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$CudaVersion
  )

  Write-Step "Ensuring cuDNN $Version"

  $cudaMajor = ($CudaVersion -split '\.')[0]
  $cudnnRoot = Get-CudnnInstallRoot -Version $Version -CudaVersion $CudaVersion
  $installedVersion = Get-CudnnInstalledVersion -CudnnRoot $cudnnRoot

  if (-not $ForceReinstall -and (Test-CudnnVersionMatch -DetectedVersion $installedVersion -RequestedVersion $Version)) {
    Write-Host "cuDNN $Version already available at $cudnnRoot"
    Set-ManifestPathValue -Name "cudnn_root" -Value $cudnnRoot
    Set-ManifestStateValue -Name "cudnn_installed_by_script" -Value $false
    return $cudnnRoot
  }

  if (-not $ForceReinstall) {
    $modernInstallRoot = Get-CudnnModernInstallRoot -Version $Version -CudaVersion $CudaVersion
    if ($modernInstallRoot) {
      #region debug-point cudnn-modern-layout-detected
      Write-DebugPoint -Id "cudnn-modern-layout-detected" -Data @{
        requested_version = $Version
        cuda_version = $CudaVersion
        installed_root = $modernInstallRoot
      }
      #endregion
      $compatRoot = New-CudnnCompatRootFromModernInstall -InstalledRoot $modernInstallRoot -Version $Version -CudaVersion $CudaVersion
      Write-Host "Using installed cuDNN from: $modernInstallRoot"
      Write-Host "Prepared build-compatible cuDNN layout at: $compatRoot"
      Set-ManifestPathValue -Name "cudnn_root" -Value $compatRoot
      Set-ManifestStateValue -Name "cudnn_installed_by_script" -Value $false
      Set-ManifestStateValue -Name "cudnn_source" -Value "modern_installer_layout"
      return $compatRoot
    }
  }

  $downloadDir = Join-Path $WorkRoot "downloads"
  Ensure-Directory -Path $downloadDir

  #region debug-point cudnn-install-required
  Write-DebugPoint -Id "cudnn-install-required" -Data @{
    version = $Version
    cuda_version = $CudaVersion
    cudnn_root = $cudnnRoot
  }
  #endregion
  Assert-Administrator -Reason "installing cuDNN"
  $archiveUrl = "https://developer.download.nvidia.com/compute/cudnn/redist/cudnn/windows-x86_64/cudnn-windows-x86_64-$Version`_cuda$cudaMajor-archive.zip"
  $archivePath = Join-Path $downloadDir ("cudnn-windows-x86_64-{0}-cuda{1}.zip" -f $Version, $cudaMajor)
  $extractRoot = Join-Path $WorkRoot ("extract-cudnn-{0}-cuda{1}" -f $Version, $cudaMajor)

  if (Test-Path $extractRoot) {
    Remove-DirectoryTree -Path $extractRoot
  }

  if (-not (Test-Path $archivePath)) {
    Write-Host "Downloading cuDNN from $archiveUrl"
    Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath
  }

  Expand-Archive -Path $archivePath -DestinationPath $extractRoot -Force
  $archiveRoot = Get-ChildItem $extractRoot -Directory | Select-Object -First 1
  if (-not $archiveRoot) {
    throw "Unable to find extracted cuDNN directory under $extractRoot"
  }

  Ensure-Directory -Path $cudnnRoot
  Ensure-Directory -Path (Join-Path $cudnnRoot "bin")
  Ensure-Directory -Path (Join-Path $cudnnRoot "include")
  Ensure-Directory -Path (Join-Path $cudnnRoot "lib")
  Ensure-Directory -Path (Join-Path $cudnnRoot "lib\x64")

  if (Test-Path (Join-Path $archiveRoot.FullName "bin")) {
    Copy-DirectoryContents -SourceDirectory (Join-Path $archiveRoot.FullName "bin") -DestinationDirectory (Join-Path $cudnnRoot "bin")
  }
  if (Test-Path (Join-Path $archiveRoot.FullName "include")) {
    Copy-DirectoryContents -SourceDirectory (Join-Path $archiveRoot.FullName "include") -DestinationDirectory (Join-Path $cudnnRoot "include")
  }
  if (Test-Path (Join-Path $archiveRoot.FullName "lib")) {
    Copy-DirectoryContents -SourceDirectory (Join-Path $archiveRoot.FullName "lib") -DestinationDirectory (Join-Path $cudnnRoot "lib")
  }
  if (Test-Path (Join-Path $archiveRoot.FullName "lib\x64")) {
    Copy-DirectoryContents -SourceDirectory (Join-Path $archiveRoot.FullName "lib\x64") -DestinationDirectory (Join-Path $cudnnRoot "lib\x64")
  }

  $manifest = [ordered]@{
    cudnn_version = $Version
    cuda_major = $cudaMajor
    archive_url = $archiveUrl
    installed_at = (Get-Date).ToString("s")
  }
  $manifestJson = $manifest | ConvertTo-Json -Depth 3
  Write-TextFile -Path (Join-Path $cudnnRoot "seasonengine-cudnn-install.json") -Value $manifestJson -Encoding ASCII

  $installedVersion = Get-CudnnInstalledVersion -CudnnRoot $cudnnRoot
  if (-not (Test-CudnnVersionMatch -DetectedVersion $installedVersion -RequestedVersion $Version)) {
    throw "cuDNN installation verification failed. Expected $Version, got '$installedVersion'."
  }

  Set-ManifestPathValue -Name "cudnn_root" -Value $cudnnRoot
  Set-ManifestStateValue -Name "cudnn_installed_by_script" -Value $true
  return $cudnnRoot
}

function Get-OrtSourceDir {
  return (Join-Path $WorkRoot "onnxruntime")
}

function Ensure-OrtCheckout {
  param([Parameter(Mandatory = $true)][string]$Ref)

  Write-Step "Ensuring ONNX Runtime checkout at $Ref"

  $sourceDir = $null
  Ensure-Directory -Path $WorkRoot

  if (-not [string]::IsNullOrWhiteSpace($LocalOrtSourceDir) -and (Test-Path $LocalOrtSourceDir)) {
    $sourceDir = (Resolve-Path $LocalOrtSourceDir).Path
    #region debug-point ort-local-source-detected
    Write-DebugPoint -Id "ort-local-source-detected" -Data @{
      source_dir = $sourceDir
      is_git_repo = (Test-Path (Join-Path $sourceDir ".git"))
    }
    #endregion

    if (-not (Test-Path (Join-Path $sourceDir "build.bat"))) {
      throw "Local ONNX Runtime source directory is missing build.bat: $sourceDir"
    }

    if (-not (Test-Path (Join-Path $sourceDir "cmake\deps.txt"))) {
      throw "Local ONNX Runtime source directory is missing cmake\\deps.txt: $sourceDir"
    }

    if (-not (Test-Path (Join-Path $sourceDir ".git"))) {
      Write-Host "Using local ONNX Runtime source snapshot: $sourceDir"
      Set-ManifestPathValue -Name "ort_source_dir" -Value $sourceDir
      Set-ManifestStateValue -Name "ort_source_kind" -Value "local_snapshot"
      return $sourceDir
    }
  }

  if (-not $sourceDir) {
    $sourceDir = Get-OrtSourceDir
  }

  if (-not (Test-Path $sourceDir)) {
    Invoke-External -FilePath "git.exe" -ArgumentList @("clone", "https://github.com/microsoft/onnxruntime.git", $sourceDir)
  }

  if (-not (Test-Path (Join-Path $sourceDir ".git"))) {
    throw "$sourceDir exists but is not a git repository."
  }

  $status = (& git -C $sourceDir status --porcelain=v1)
  if ($status) {
    throw "The ONNX Runtime working tree at $sourceDir is dirty. Clean it or remove the directory first."
  }

  Invoke-External -FilePath "git.exe" -ArgumentList @("-C", $sourceDir, "fetch", "--tags", "--force", "origin")
  Invoke-External -FilePath "git.exe" -ArgumentList @("-C", $sourceDir, "checkout", "--force", $Ref)
  Invoke-External -FilePath "git.exe" -ArgumentList @("-C", $sourceDir, "submodule", "sync", "--recursive")
  Invoke-External -FilePath "git.exe" -ArgumentList @("-C", $sourceDir, "submodule", "update", "--init", "--recursive")

  Set-ManifestPathValue -Name "ort_source_dir" -Value $sourceDir
  Set-ManifestStateValue -Name "ort_source_kind" -Value "git_checkout"
  return $sourceDir
}

function Expand-DownloadZip {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$ZipPath,
    [Parameter(Mandatory = $true)][string]$ExtractRoot
  )

  if (-not (Test-Path $ZipPath)) {
    Invoke-WebRequest -Uri $Url -OutFile $ZipPath
  }

  if (Test-Path $ExtractRoot) {
    Remove-DirectoryTree -Path $ExtractRoot
  }

  Expand-Archive -Path $ZipPath -DestinationPath $ExtractRoot -Force
  $innerDir = Get-ChildItem $ExtractRoot -Directory | Select-Object -First 1
  if (-not $innerDir) {
    throw "No directory found after extracting $ZipPath"
  }

  return $innerDir.FullName
}

function Prepare-OrtDependencies {
  param([Parameter(Mandatory = $true)][string]$OrtSourceDir)

  Write-Step "Preparing ONNX Runtime dependency sources"

  $downloadsDir = Join-Path $WorkRoot "downloads"
  $extractDir = Join-Path $WorkRoot "sources"
  Ensure-Directory -Path $downloadsDir
  Ensure-Directory -Path $extractDir

  $depsFile = Join-Path $OrtSourceDir "cmake\deps.txt"
  if (-not (Test-Path $depsFile)) {
    throw "deps.txt not found at $depsFile"
  }

  $eigenLine = Get-Content $depsFile | Where-Object { $_ -match '^eigen;' } | Select-Object -First 1
  $eigenMatch = if ($eigenLine) { [regex]::Match($eigenLine, '^eigen;(\S+);') } else { $null }
  if (-not $eigenMatch -or -not $eigenMatch.Success) {
    throw "Unable to parse Eigen entry from $depsFile"
  }

  $eigenSourceDir = Expand-DownloadZip -Url $eigenMatch.Groups[1].Value -ZipPath (Join-Path $downloadsDir "eigen.zip") -ExtractRoot (Join-Path $extractDir "eigen")
  $dateSourceDir = Expand-DownloadZip -Url "https://github.com/HowardHinnant/date/archive/refs/tags/v3.0.1.zip" -ZipPath (Join-Path $downloadsDir "date.zip") -ExtractRoot (Join-Path $extractDir "date")
  $cpuinfoSourceDir = Expand-DownloadZip -Url "https://github.com/pytorch/cpuinfo/archive/ca678952a9a8eaa6de112d154e8e104b22f9ab3f.zip" -ZipPath (Join-Path $downloadsDir "cpuinfo.zip") -ExtractRoot (Join-Path $extractDir "cpuinfo")

  return @{
    Eigen = $eigenSourceDir
    Date = $dateSourceDir
    CpuInfo = $cpuinfoSourceDir
  }
}

function Patch-OrtMutexHeader {
  param([Parameter(Mandatory = $true)][string]$OrtSourceDir)

  $candidates = @(
    (Join-Path $OrtSourceDir "include\onnxruntime\core\platform\ort_mutex.h"),
    (Join-Path $OrtSourceDir "onnxruntime\core\platform\ort_mutex.h")
  )

  foreach ($candidate in $candidates) {
    if (-not (Test-Path $candidate)) {
      continue
    }

    $content = Get-Content $candidate -Raw
    if ($content -notmatch '#include <chrono>') {
      Write-TextFile -Path $candidate -Value ("#include <chrono>`r`n" + $content)
    }
    return
  }

  Write-Warning "ort_mutex.h was not found. Skipping chrono compatibility patch."
}

function Ensure-CudaJunction {
  param([Parameter(Mandatory = $true)][string]$CudaRoot)

  $junctionPath = Join-Path $WorkRoot "cuda"
  if (Test-Path $junctionPath) {
    try {
      $target = (Get-Item $junctionPath).Target
      if ($target -and $target -contains $CudaRoot) {
        Set-ManifestPathValue -Name "cuda_junction" -Value $junctionPath
        return $junctionPath
      }
    } catch {
    }
    throw "$junctionPath already exists and does not point to $CudaRoot. Remove or rename it before running this script."
  }

  Ensure-Directory -Path $WorkRoot
  New-Item -ItemType Junction -Path $junctionPath -Target $CudaRoot -Force | Out-Null
  Set-ManifestPathValue -Name "cuda_junction" -Value $junctionPath
  return $junctionPath
}

function Get-SanitizedPath {
  param([Parameter(Mandatory = $true)][string]$CurrentPath)

  $parts = @()
  foreach ($part in ($CurrentPath -split ';')) {
    if ([string]::IsNullOrWhiteSpace($part)) {
      continue
    }
    if ($part -match '(?i)\\NVIDIA GPU Computing Toolkit\\CUDA\\v\d+(\.\d+)?') {
      continue
    }
    $parts += $part
  }

  return ($parts -join ';')
}

function Invoke-OrtBuild {
  param(
    [Parameter(Mandatory = $true)][string]$OrtSourceDir,
    [Parameter(Mandatory = $true)][string]$CudaRoot,
    [Parameter(Mandatory = $true)][string]$CudnnRoot,
    [Parameter(Mandatory = $true)][string]$VCVarsPath,
    [Parameter(Mandatory = $true)][hashtable]$Dependencies
  )

  Write-Step "Building ONNX Runtime"

  $cudaSeries = ($CudaVersion -split '\.')[0..1] -join "."
  $cudaParts = $cudaSeries -split '\.'
  $cudaMajor = $cudaParts[0]
  $cudaMinor = $cudaParts[1]
  $cudaAlias = Ensure-CudaJunction -CudaRoot $CudaRoot
  $sanitizedPath = Get-SanitizedPath -CurrentPath $env:PATH
  $cmdPath = Join-Path $WorkRoot "build-onnxruntime.cmd"
  $skipSubmoduleSync = -not (Test-Path (Join-Path $OrtSourceDir ".git"))
  $buildVCVarsPath = Resolve-OrtBuildVCVarsPath -PreferredPath $VCVarsPath

  $cmdLines = @(
    "@echo off",
    "setlocal",
    "set ""CUDA=$cudaAlias""",
    "set ""CUDA_PATH=%CUDA%""",
    "set ""CUDA_HOME=%CUDA%""",
    "set ""CUDNN_HOME=$CudnnRoot""",
    "set ""CUDACXX=%CUDA%\bin\nvcc.exe""",
    "set ""PATH=%CUDA%\bin;$CudnnRoot\bin;$sanitizedPath""",
    "for /f ""tokens=1 delims=="" %%A in ('set CUDA_PATH_V 2^>nul') do set ""%%A=""",
    "set ""CUDA_PATH_V${cudaMajor}_${cudaMinor}=%CUDA%""",
    "call ""$buildVCVarsPath""",
    "set CL=/D_SILENCE_ALL_CXX23_DEPRECATION_WARNINGS",
    "cd /d ""$OrtSourceDir""",
    "echo ============================================",
    "echo Building ONNX Runtime",
    "echo   ORT ref:  $OrtRef",
    "echo   CUDA:     %CUDA_PATH%",
    "echo   cuDNN:    %CUDNN_HOME%",
    "echo   Ninja jobs: $ParallelJobs",
    "echo   NVCC threads: $NvccThreads",
    "echo   CUDA archs: $CudaArchitectures",
    "echo ============================================",
    "call build.bat ^",
    "  --use_cuda ^",
    "  --use_dml ^",
    "  --config Release ^",
    "  --parallel $ParallelJobs ^",
    "  --nvcc_threads $NvccThreads ^",
    "  --skip_submodule_sync ^",
    "  --skip_tests ^",
    "  --build_shared_lib ^",
    "  --cmake_generator Ninja ^",
    "  --cuda_home ""%CUDA%"" ^",
    "  --cudnn_home ""$CudnnRoot"" ^",
    "  --cuda_version ""$cudaSeries"" ^",
    "  --cmake_extra_defines CMAKE_SYSTEM_VERSION=10.0.19041.0 onnxruntime_USE_PREINSTALLED_EIGEN=ON eigen_SOURCE_PATH=$($Dependencies.Eigen) CMAKE_CUDA_COMPILER=%CUDA%\bin\nvcc.exe ""CMAKE_CUDA_FLAGS=-diag-suppress=221 -Wno-deprecated-gpu-targets"" ""CMAKE_CUDA_ARCHITECTURES=$CudaArchitectures"" FETCHCONTENT_SOURCE_DIR_date=$($Dependencies.Date) FETCHCONTENT_SOURCE_DIR_pytorch_cpuinfo=$($Dependencies.CpuInfo)",
    "if errorlevel 1 exit /b 1"
  )

  Write-TextFile -Path $cmdPath -Value ($cmdLines -join "`r`n") -Encoding ASCII
  Invoke-External -FilePath "cmd.exe" -ArgumentList @("/d", "/c", $cmdPath)
}

function Collect-OrtArtifacts {
  param([Parameter(Mandatory = $true)][string]$OrtSourceDir)

  Write-Step "Collecting ONNX Runtime artifacts"

  $artifactRoot = Join-Path $WorkRoot "artifacts\onnxruntime"
  Ensure-Directory -Path $artifactRoot
  Set-ManifestPathValue -Name "artifact_root" -Value $artifactRoot

  $buildRoot = Join-Path $OrtSourceDir "build\Windows"
  $dlls = Get-ChildItem -Path $buildRoot -Recurse -Filter "onnxruntime*.dll" -ErrorAction SilentlyContinue | Sort-Object FullName -Unique
  if (-not $dlls) {
    throw "No onnxruntime DLLs were found under $buildRoot"
  }

  foreach ($dll in $dlls) {
    Copy-FileToDirectory -SourceFile $dll.FullName -DestinationDirectory $artifactRoot
  }

  Write-Host "Artifacts copied to $artifactRoot"
}

Ensure-Directory -Path $WorkRoot
Set-ManifestPathValue -Name "work_root" -Value $WorkRoot
Ensure-Git
$pythonCommand = Ensure-Python311
Ensure-CMake
$vcvarsPath = Ensure-VSBuildTools
$cudaRoot = Ensure-CudaToolkit -Version $CudaVersion
$cudnnRoot = Ensure-Cudnn -Version $CudnnVersion -CudaVersion $CudaVersion
$ortSourceDir = Ensure-OrtCheckout -Ref $OrtRef
$dependencies = Prepare-OrtDependencies -OrtSourceDir $ortSourceDir
Patch-OrtMutexHeader -OrtSourceDir $ortSourceDir
Invoke-OrtBuild -OrtSourceDir $ortSourceDir -CudaRoot $cudaRoot -CudnnRoot $cudnnRoot -VCVarsPath $vcvarsPath -Dependencies $dependencies
Collect-OrtArtifacts -OrtSourceDir $ortSourceDir
Set-ManifestStateValue -Name "build_completed" -Value $true

Write-Step "Done"
Write-Host "Build completed successfully."
Write-Host "Workspace: $WorkRoot"
Write-Host "Artifacts: $(Join-Path $WorkRoot 'artifacts\onnxruntime')"
