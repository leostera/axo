param(
    [Parameter(Mandatory)][string]$Bun,
    [Parameter(Mandatory)][string]$Destination
)
$ErrorActionPreference = 'Stop'
$bunExe = (Resolve-Path -LiteralPath $Bun).Path
if ((& $bunExe --version) -ne '1.4.5' -or $LASTEXITCODE) { throw 'Supply Bun 1.4.5 for Windows.' }
if (Test-Path -LiteralPath $Destination) { throw 'Use a new staging directory.' }
$root = (New-Item -ItemType Directory -Path $Destination).FullName
Copy-Item -LiteralPath $bunExe -Destination (Join-Path $root 'bun.exe')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'pi/package.json'),(Join-Path $PSScriptRoot 'pi/bun.lock') -Destination $root
Push-Location $root
try {
    & (Join-Path $root 'bun.exe') install --linker hoisted --frozen-lockfile --ignore-scripts
    if ($LASTEXITCODE) { throw 'Could not stage the pinned Pi runtime.' }
    if (Get-ChildItem -LiteralPath (Join-Path $root 'node_modules') -Recurse -Attributes ReparsePoint) {
        throw 'The Pi bundle must not contain junctions or links.'
    }
}
finally { Pop-Location }
Write-Output $root
