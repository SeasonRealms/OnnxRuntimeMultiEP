# OnnxRuntimeMultiEP

`OnnxRuntimeMultiEP` is a practical build-and-packaging workspace for self-built ONNX Runtime distributions with multiple Execution Providers.

Project repository:

- [https://github.com/SeasonRealms/OnnxRuntimeMultiEP](https://github.com/SeasonRealms/OnnxRuntimeMultiEP)

NuGet consumers can use the repository above to review the CUDA and cuDNN build and packaging scripts, along with the documented version guidance and integration notes.

The current validated target is:

- Windows x64
- ONNX Runtime `1.26.0`
- CPU + DirectML + CUDA execution providers
- CUDA `12.8.1`
- cuDNN `9.8.0.87`

The project name is intentionally centered on `MultiEP` so that developers can immediately understand that the goal is not only bundling binaries, but also documenting how to build, package, and ship ONNX Runtime with multiple execution providers across platforms.

Future targets may include:

- Windows x64 / Arm64
- Linux x64 / Arm64
- CUDAExecutionProvider
- DirectMLExecutionProvider
- MIGraphXExecutionProvider
- OpenVINOExecutionProvider
- CoreMLExecutionProvider
- NNAPIExecutionProvider

## What Is Included

- Local build script for ONNX Runtime
- Local packaging script for CUDA and cuDNN runtime DLLs
- GitHub Actions workflow for building ONNX Runtime
- GitHub Actions workflow for packaging CUDA and cuDNN runtime DLLs
- A validated Windows x64 runtime snapshot prepared for Release assets and NuGet packaging

## Repository Layout

```text
OnnxRuntimeMultiEP/
  outputs/
    onnxruntime-runtime/
    runtime-metadata/
    runtimes/
      win-x64/
        native/
  scripts/
    build-onnxruntime-local.ps1
    package-cuda-cudnn-runtime-local.ps1
  workflows/
    build-onnxruntime-cpu-cuda-dml.yml
    package-cuda-cudnn-runtime.yml
  LICENSE
  OnnxRuntimeMultiEP.Runtime.win-x64.nuspec
  README.md
```

## Key Practical Findings

### GitHub Actions is still useful

The GitHub Actions workflows are kept because they are fully automated and still valuable for:

- older ONNX Runtime versions such as `1.19.x`
- users with larger GitHub-hosted runners
- users with self-hosted Windows runners

### Local builds are often more reliable for ONNX Runtime 1.26.0

For ONNX Runtime `1.26.0`, Windows hosted runners can fail with out-of-memory errors during CUDA-heavy compilation, especially around Flash Attention and CUTLASS-heavy translation units.

That is why the local PowerShell route is preserved as a first-class path.

### Local builds are not necessarily faster

Local builds avoid hosted-runner memory limits, but they are not always faster. Common bottlenecks include:

- first-time dependency downloads
- CUDA and cuDNN installation time
- Visual Studio configuration
- machine-specific permission issues
- CPU limits on consumer hardware

In practice, preinstalling Python, CUDA, cuDNN, and the ONNX Runtime source tree often produces a smoother result than relying on a fully automatic first-run setup.

## Current Runtime Outputs

### ORT-only runtime files

The `outputs/onnxruntime-runtime` directory currently contains the validated ONNX Runtime side of the bundle:

- `onnxruntime.dll`
- `onnxruntime_providers_cuda.dll`
- `onnxruntime_providers_shared.dll`
- `DirectML.dll`
- `DirectML.Debug.dll`

This directory is the safest starting point for public sharing because it does not represent a direct redistribution of CUDA or cuDNN runtime DLLs.

### Full Windows x64 runtime bundle

The `outputs/runtimes/win-x64/native` directory contains the combined Windows x64 runtime layout intended for:

- GitHub Release assets
- local validation
- NuGet packaging

This combined layout includes:

- ONNX Runtime DLLs
- DirectML DLLs
- CUDA runtime DLLs
- cuDNN runtime DLLs

This full bundle is useful for local validation and Release preparation, but it is not the default NuGet payload in this repository.

## NVIDIA Redistribution Notice

This repository includes scripts and a packaging layout that can work with CUDA and cuDNN runtime DLLs.

Before publishing any package or Release asset that contains NVIDIA binaries, you are responsible for confirming that your redistribution complies with NVIDIA's licensing and redistribution terms.

If you want a repository-safe public source tree, keep the scripts and metadata in Git, and publish NVIDIA-containing artifacts separately after legal review.

The default NuGet package in this repository intentionally excludes CUDA and cuDNN DLLs.

## How To Add CUDA And cuDNN

This repository does not ship CUDA or cuDNN runtime DLLs in the default NuGet package.

If you need CUDA execution at runtime, generate and integrate the NVIDIA runtime files yourself:

1. Build the ONNX Runtime bundle with the provided scripts.
2. Run the local packaging script to collect CUDA and cuDNN runtime DLLs.
3. Integrate the generated NVIDIA DLLs into your own deployment layout.

If you download CUDA or cuDNN manually instead of using the scripts, make sure the versions match the ONNX Runtime build you are shipping.

For the current validated setup, the expected versions are:

- CUDA `12.8.1`
- cuDNN `9.8.0.87`

## Building Locally

Use the local build script when GitHub Actions is not reliable enough for ONNX Runtime `1.26.0`.

Example:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-onnxruntime-local.ps1 `
  -OrtRef v1.26.0 `
  -CudaVersion 12.8.1 `
  -CudnnVersion 9.8.0.87 `
  -ParallelJobs 2 `
  -NvccThreads 1
```

## Packaging Locally

After a successful local build, package the runtime layout with:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\package-cuda-cudnn-runtime-local.ps1
```

The generated manifest is stored in:

- `outputs/runtime-metadata/runtime-manifest.json`

## Required Managed Package Version

When consuming this runtime in an application, including upstream class libraries, make sure the managed reference is:

- `Microsoft.ML.OnnxRuntime.Managed` version `1.26.0`

Do not mix this runtime bundle with a different managed ONNX Runtime version.

If the managed package version does not match the native runtime version, the final executable can fail with runtime invocation errors, entry-point binding errors, or provider-loading failures.

## Packing the Current NuGet Package

The included `.nuspec` is designed for the current validated Windows x64 ORT-only runtime layout.

Example:

```powershell
nuget pack .\OnnxRuntimeMultiEP.Runtime.win-x64.nuspec -Version 1.26.0-multiep-winx64 -OutputDirectory .\artifacts
```

The package layout maps `outputs/onnxruntime-runtime` into the standard NuGet runtime folder:

- `runtimes/win-x64/native`

## Intended Audience

This project is intended for developers who need:

- a self-built ONNX Runtime runtime pack
- explicit control over execution provider selection
- reproducible local Windows build steps
- a starting point for future cross-platform EP packaging

## License

This project is released under the MIT License.
