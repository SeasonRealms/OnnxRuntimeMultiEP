[CmdletBinding()]
param(
  [string]$CudaVersion = "12.8.1",
  [string]$CudnnVersion = "9.8.0.87",
  [string]$OrtBuildDir = "C:\Docs\TRAE\onnxruntime-1.26.0\build\Windows\Release",
  [string]$CudaPath = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.8",
  [string]$CudnnRoot = "C:\Program Files\NVIDIA\CUDNN\v9.8",
  [string]$OutputRoot = (Join-Path $PSScriptRoot "out-local-runtime")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Ensure-Directory {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Write-TextFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Value
  )

  $parent = Split-Path -Parent $Path
  if ($parent) {
    Ensure-Directory -Path $parent
  }

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Value, $utf8NoBom)
}

function Copy-FileToDirectory {
  param(
    [Parameter(Mandatory = $true)][string]$SourceFile,
    [Parameter(Mandatory = $true)][string]$DestinationDirectory
  )

  Ensure-Directory -Path $DestinationDirectory
  $targetPath = Join-Path $DestinationDirectory ([System.IO.Path]::GetFileName($SourceFile))
  [System.IO.File]::Copy($SourceFile, $targetPath, $true)
  return $targetPath
}

function Get-FileVersionOrNull {
  param([Parameter(Mandatory = $true)][string]$Path)

  try {
    return (Get-Item $Path).VersionInfo.FileVersion
  } catch {
    return $null
  }
}

function Get-CudaMajorMinor {
  param([Parameter(Mandatory = $true)][string]$Version)

  $parts = $Version.Split(".")
  if ($parts.Count -lt 2) {
    throw "Version must contain major.minor: $Version"
  }

  return "$($parts[0]).$($parts[1])"
}

function Get-CudnnBinPath {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$CudaVersion
  )

  $cudaSeries = Get-CudaMajorMinor -Version $CudaVersion
  $candidates = @(
    (Join-Path $Root "bin\$cudaSeries"),
    (Join-Path $Root "bin")
  )

  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) {
      return $candidate
    }
  }

  throw "cuDNN bin directory not found under $Root"
}

function Copy-MatchingDlls {
  param(
    [Parameter(Mandatory = $true)][string]$SourceDirectory,
    [Parameter(Mandatory = $true)][string[]]$Patterns,
    [Parameter(Mandatory = $true)][string]$DestinationDirectory,
    [string[]]$ExcludePatterns = @()
  )

  Ensure-Directory -Path $DestinationDirectory

  $copied = @{}
  foreach ($pattern in $Patterns) {
    $matches = @(Get-ChildItem -Path $SourceDirectory -Filter $pattern -File -ErrorAction SilentlyContinue)
    foreach ($match in $matches) {
      $excluded = $false
      foreach ($excludePattern in $ExcludePatterns) {
        if ($match.Name -like $excludePattern) {
          $excluded = $true
          break
        }
      }

      if ($excluded -or $copied.Contains($match.Name)) {
        continue
      }

      $targetPath = Copy-FileToDirectory -SourceFile $match.FullName -DestinationDirectory $DestinationDirectory
      $copied[$match.Name] = [pscustomobject]@{
        name = $match.Name
        source = $match.FullName
        destination = $targetPath
        file_version = Get-FileVersionOrNull -Path $targetPath
      }
    }
  }

  return @($copied.Values | Sort-Object name)
}

function Copy-ExistingDirectoriesToBundle {
  param(
    [Parameter(Mandatory = $true)][string[]]$SourceDirectories,
    [Parameter(Mandatory = $true)][string]$DestinationDirectory
  )

  Ensure-Directory -Path $DestinationDirectory

  foreach ($sourceDir in $SourceDirectories) {
    if (-not (Test-Path $sourceDir)) {
      continue
    }

    foreach ($dll in (Get-ChildItem -Path $sourceDir -Filter *.dll -File -ErrorAction SilentlyContinue)) {
      [System.IO.File]::Copy($dll.FullName, (Join-Path $DestinationDirectory $dll.Name), $true)
    }
  }
}

if (-not (Test-Path $OrtBuildDir)) {
  throw "ONNX Runtime build directory not found: $OrtBuildDir"
}
if (-not (Test-Path $CudaPath)) {
  throw "CUDA installation not found: $CudaPath"
}

$cudaBin = Join-Path $CudaPath "bin"
if (-not (Test-Path $cudaBin)) {
  throw "CUDA bin directory not found: $cudaBin"
}

$cudnnBin = Get-CudnnBinPath -Root $CudnnRoot -CudaVersion $CudaVersion

$ortOut = Join-Path $OutputRoot "onnxruntime-runtime"
$cudaOut = Join-Path $OutputRoot "cuda-runtime"
$cudnnOut = Join-Path $OutputRoot "cudnn-runtime"
$bundleOut = Join-Path $OutputRoot "runtimes\win-x64\native"
$metadataOut = Join-Path $OutputRoot "runtime-metadata"

foreach ($dir in @($ortOut, $cudaOut, $cudnnOut, $bundleOut, $metadataOut)) {
  Ensure-Directory -Path $dir
}

$ortPatterns = @(
  "onnxruntime.dll",
  "onnxruntime_providers_*.dll",
  "DirectML.dll",
  "DirectML.Debug.dll"
)
$ortExcludePatterns = @(
  "*test*",
  "custom_op_*",
  "example_plugin_*"
)

$cudaPatterns = @(
  "cudart64_*.dll",
  "cublas64_*.dll",
  "cublasLt64_*.dll",
  "cufft64_*.dll",
  "curand64_*.dll",
  "cusolver64_*.dll",
  "cusparse64_*.dll",
  "nvrtc64_*.dll",
  "nvrtc-builtins64_*.dll",
  "nvJitLink_*.dll"
)

$cudnnPatterns = @(
  "cudnn64_*.dll",
  "cudnn_ops64_*.dll",
  "cudnn_cnn64_*.dll",
  "cudnn_adv64_*.dll",
  "cudnn_engines_precompiled64_*.dll",
  "cudnn_engines_runtime_compiled64_*.dll",
  "cudnn_heuristic64_*.dll",
  "cudnn_graph64_*.dll"
)

$ortFiles = Copy-MatchingDlls -SourceDirectory $OrtBuildDir -Patterns $ortPatterns -DestinationDirectory $ortOut -ExcludePatterns $ortExcludePatterns
$cudaFiles = Copy-MatchingDlls -SourceDirectory $cudaBin -Patterns $cudaPatterns -DestinationDirectory $cudaOut
$cudnnFiles = Copy-MatchingDlls -SourceDirectory $cudnnBin -Patterns $cudnnPatterns -DestinationDirectory $cudnnOut

if ($ortFiles.Count -eq 0) {
  throw "No ONNX Runtime DLLs were collected from $OrtBuildDir"
}
if ($cudaFiles.Count -eq 0) {
  throw "No CUDA runtime DLLs were collected from $cudaBin"
}
if ($cudnnFiles.Count -eq 0) {
  throw "No cuDNN runtime DLLs were collected from $cudnnBin"
}

Copy-ExistingDirectoriesToBundle -SourceDirectories @($ortOut, $cudaOut, $cudnnOut) -DestinationDirectory $bundleOut

$manifest = [ordered]@{
  generated_at = (Get-Date).ToString("s")
  cuda_version = $CudaVersion
  cudnn_version = $CudnnVersion
  ort_build_dir = $OrtBuildDir
  cuda_path = $CudaPath
  cuda_bin = $cudaBin
  cudnn_root = $CudnnRoot
  cudnn_bin = $cudnnBin
  output_root = $OutputRoot
  analysis = "Rewritten from package-cuda-cudnn-runtime.yml for local Windows packaging. CUDA/cuDNN runtime DLLs are copied directly from local machine installs, and ONNX Runtime DLLs are copied from the local build output."
  validation = "All packaged DLLs come only from the configured local ORT build directory, CUDA bin directory, and cuDNN bin directory."
  ort_files = $ortFiles
  cuda_files = $cudaFiles
  cudnn_files = $cudnnFiles
}

$manifestJson = $manifest | ConvertTo-Json -Depth 8
Write-TextFile -Path (Join-Path $metadataOut "runtime-manifest.json") -Value $manifestJson

Write-Host ""
Write-Host "Collected ONNX Runtime DLLs: $($ortFiles.Count)"
Write-Host "Collected CUDA DLLs:        $($cudaFiles.Count)"
Write-Host "Collected cuDNN DLLs:      $($cudnnFiles.Count)"
Write-Host "Bundle output:             $bundleOut"
Write-Host "Metadata:                  $(Join-Path $metadataOut 'runtime-manifest.json')"
