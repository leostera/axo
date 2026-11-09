param(
    [string]$BazelRoot = "$($env:SystemDrive)\axo-bazel",
    [switch]$Test,
    [switch]$Run
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Push-Location $repo
try {
    $bazel = (Get-Command bazelisk -ErrorAction SilentlyContinue).Source
    if (-not $bazel) { $bazel = (Get-Command bazel -ErrorAction SilentlyContinue).Source }
    if (-not $bazel) {
        $candidate = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Bazel.Bazelisk_Microsoft.Winget.Source_8wekyb3d8bbwe\bazelisk.exe'
        if (Test-Path -LiteralPath $candidate) { $bazel = $candidate }
    }
    if (-not $bazel) { throw 'Install Bazelisk: winget install --id Bazel.Bazelisk --exact' }
    $dotnet = (Get-Command dotnet -ErrorAction SilentlyContinue).Source
    if (-not $dotnet) { $dotnet = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe' }
    if (-not (Test-Path -LiteralPath $dotnet)) { throw 'Install the .NET 10 SDK.' }
    $git = (Get-Command git -ErrorAction Stop).Source
    $gitRoot = Split-Path (Split-Path $git -Parent) -Parent
    $bash = Join-Path $gitRoot 'bin\bash.exe'
    if (-not (Test-Path -LiteralPath $bash)) { throw 'Install Git for Windows including Bash.' }
    $env:BAZEL_SH = $bash.Replace('\', '/')
    $env:CARGO_NET_GIT_FETCH_WITH_CLI = 'true'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    # Cua has paths beyond MAX_PATH. Cargo must use Git CLI and Git must accept long paths.
    if ((& $git config --get core.longpaths) -ne 'true') {
        throw 'Enable Git long paths first: git config --global core.longpaths true'
    }
    $targets = @('//crates/axod:axod')
    $verb = 'build'
    if ($Test) {
        $verb = 'test'
        $targets += @('//crates/axo-protocol:axo_protocol_tests', '//crates/axo-agent:axo_agent_tests', '//crates/axo-store:axo_store_tests', '//crates/axo-ipc:axo_ipc_tests', '//crates/axo-relay:axo_relay_tests', '//crates/axo-server:axo_server_tests', '//crates/axo-computer:axo_computer_tests', '//crates/axo-agent:fake_codex', '//crates/axo-seal:seal_fixture', '//crates/axo-seal:axo_seal_tests', '//crates/axo-questions:axo_questions_tests', '//crates/axo-computer-use:axo_computer_use_tests')
    }
    & $bazel "--output_user_root=$BazelRoot" $verb @targets '--repo_env=CARGO_NET_GIT_FETCH_WITH_CLI=true' "--repo_env=BAZEL_SH=$env:BAZEL_SH"
    if ($LASTEXITCODE -ne 0) { throw 'The Rust build or tests failed.' }
    $buildConfig=Get-Content -LiteralPath 'config.json' -Raw|ConvertFrom-Json
    $revision=& $git rev-parse HEAD
    & $dotnet publish windows/Axo/Axo.csproj -c Release --self-contained false -o dist/Axo-Windows --nologo "-p:Version=$($buildConfig.version).0" "-p:FileVersion=$($buildConfig.version).0.$($buildConfig.builds.axod)" "-p:InformationalVersion=$($buildConfig.version).0-windows.$($buildConfig.builds.axod)+$revision" '-p:IncludeSourceRevisionInInformationalVersion=false'
    if ($LASTEXITCODE -ne 0) { throw 'The desktop client build failed.' }
    Copy-Item -LiteralPath 'bazel-bin\crates\axod\axod.exe' -Destination 'dist\Axo-Windows\axod.exe' -Force
    New-Item -ItemType Directory -Path 'dist/Axo-Windows/licenses' -Force | Out-Null
    Copy-Item -LiteralPath 'third_party/cua/LICENSE.md' -Destination 'dist/Axo-Windows/licenses/Cua-LICENSE.md' -Force
    Copy-Item -LiteralPath 'third_party/cua/THIRD_PARTY_NOTICES.md' -Destination 'dist/Axo-Windows/licenses/Cua-THIRD_PARTY_NOTICES.md' -Force
    Copy-Item -LiteralPath 'windows/README.md' -Destination 'dist/Axo-Windows/README.md' -Force
    if ($Test) {
        & $dotnet run --project windows/Tests/Tests.csproj -c Release -- 'bazel-bin\crates\axod\axod.exe' 'bazel-bin\crates\axo-agent\fake_codex.exe'
        if ($LASTEXITCODE -ne 0) { throw 'Windows integration tests failed.' }
    }
    $packageRoot = (Resolve-Path 'dist/Axo-Windows').Path
    $packageFiles = @(Get-ChildItem -LiteralPath $packageRoot -File -Recurse | Where-Object { $_.Name -ne 'build-manifest.json' } | Sort-Object FullName | ForEach-Object {
        [ordered]@{ path = [IO.Path]::GetRelativePath($packageRoot, $_.FullName).Replace('\','/'); bytes = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    $manifest = [ordered]@{ version = "$($buildConfig.version).0"; axodBuild = $buildConfig.builds.axod; gitCommit = "$revision"; signature = 'NotSigned'; tests = $(if ($Test) { 'Windows Rust and integration checks passed' } else { 'Not run by this build' }); files = $packageFiles }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $packageRoot 'build-manifest.json') -Encoding utf8
    Write-Host "Built $(Join-Path $repo 'dist\Axo-Windows\Axo.exe')"
    if ($Run) { Start-Process -FilePath (Join-Path $repo 'dist\Axo-Windows\Axo.exe') }
}
finally { Pop-Location }
