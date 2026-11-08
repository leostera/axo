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
        $targets += @('//crates/axo-protocol:axo_protocol_tests', '//crates/axo-agent:axo_agent_tests', '//crates/axo-store:axo_store_tests', '//crates/axo-server:axo_server_tests', '//crates/axo-agent:fake_codex')
    }
    & $bazel "--output_user_root=$BazelRoot" $verb @targets '--repo_env=CARGO_NET_GIT_FETCH_WITH_CLI=true' "--repo_env=BAZEL_SH=$env:BAZEL_SH"
    if ($LASTEXITCODE -ne 0) { throw 'The Rust build or tests failed.' }
    & $dotnet publish windows/Axo/Axo.csproj -c Release --self-contained false -o dist/Axo-Windows --nologo
    if ($LASTEXITCODE -ne 0) { throw 'The desktop client build failed.' }
    Copy-Item -LiteralPath 'bazel-bin\crates\axod\axod.exe' -Destination 'dist\Axo-Windows\axod.exe' -Force
    if ($Test) {
        & $dotnet run --project windows/Tests/Tests.csproj -c Release -- 'bazel-bin\crates\axod\axod.exe' 'bazel-bin\crates\axo-agent\fake_codex.exe'
        if ($LASTEXITCODE -ne 0) { throw 'Windows integration tests failed.' }
    }
    Write-Host "Built $(Join-Path $repo 'dist\Axo-Windows\Axo.exe')"
    if ($Run) { Start-Process -FilePath (Join-Path $repo 'dist\Axo-Windows\Axo.exe') }
}
finally { Pop-Location }
