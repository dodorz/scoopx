@echo off
setlocal
where pwsh >nul 2>nul && set "PS_EXE=pwsh" || set "PS_EXE=powershell"
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "$c=[IO.File]::ReadAllText('%~f0');$m='__EMBEDDED_PS_START__';$i=$c.LastIndexOf($m);$nl=[char]10;$j=$c.IndexOf($nl,$i);$s=$c.Substring($j+1).TrimEnd();$p='%~f0';$d=Split-Path -Parent $p;$a='$PSCommandPath='''+$p+'''; $PSScriptRoot='''+$d+'''; $MyInvocation=[PSCustomObject]@{MyCommand=[PSCustomObject]@{Path='''+$p+'''}}; ';if($s -match '(?s)^\s*param\s*\('){$x=0;for($k=$s.IndexOf('(');$k -lt $s.Length;$k++){if($s[$k] -eq '('){$x++}elseif($s[$k] -eq ')'){$x--;if($x -eq 0){break}}};$s=$s.Substring(0,$k+1)+[char]10+$a+$s.Substring($k+1).TrimStart([char]13,[char]10)}else{$s=$a+$s};&([ScriptBlock]::Create($s)) @args" %*
exit /b %errorlevel%

#__EMBEDDED_PS_START__
<#
.SYNOPSIS
    npx-like command for scoop - install and run packages temporarily
.EXAMPLE
    scoopx jq --help
    scoopx mdcat@2.7.0 README.md
    scoopx --from 7zip 7zfm
    scoopx --from gh@2.7.0 gh --version
    scoopx shortcut 7zip
    scoopx listbin 7zip
    scoopx hasbin git
    scoopx hasbin --from 7zip 7zfm
    scoopx cache info
    scoopx cache purge
#>

$ErrorActionPreference = 'Stop'
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$SCOOPX_DATA = Join-Path $env:LOCALAPPDATA 'scoopx'
$VERSION = '1.3.0'

# ============================================================================
# Helper functions (defined first)
# ============================================================================

function Show-Help {
    param([string]$Command)

    if ($Command) {
        switch ($Command) {
            'install' {
                Write-Host "Usage: scoopx [--from] <package> <binary> [args...]"
                Write-Host "       scoopx <binary> [args...]"
                Write-Host ""
                Write-Host "Installs a package in an isolated environment, runs the specified"
                Write-Host "binary, then cleans up. Packages are cached by hash for fast re-use."
                Write-Host ""
                Write-Host "Options:"
                Write-Host "  --from          Package spec (name, url, path, with optional @version)"
                Write-Host "  --isolated      Don't reuse system scoop's apps/persist/cache"
                Write-Host "  --silent        Suppress output"
                Write-Host "  --keep          Keep cache dir after run"
                Write-Host "  --no-cache      Skip cache, force re-download"
                Write-Host "  --verbose       Verbose output"
            }
            'cache' {
                Write-Host "Usage: scoopx cache [info|list|purge|verify] [package]"
                Write-Host ""
                Write-Host "Subcommands:"
                Write-Host "  info        Show cache usage (default)"
                Write-Host "  list        Alias for info"
                Write-Host "  purge       Remove all cached packages"
                Write-Host "  purge <pkg> Remove a specific package from cache"
                Write-Host "  verify      Check cache integrity"
                Write-Host ""
                Write-Host "Options:"
                Write-Host "  --fix       Remove broken entries during verify"
            }
            'hasbin' {
                Write-Host "Usage: scoopx hasbin [--from <package>] [binary]"
                Write-Host ""
                Write-Host "Checks whether a binary exists. Prints the result unless"
                Write-Host "--silent/-q is given; always signals via exit code."
                Write-Host ""
                Write-Host "Without --from:  Searches the system PATH."
                Write-Host "With --from:     Checks the package manifest for the binary"
                Write-Host "                 (no installation performed). Omit <binary>"
                Write-Host "                 to just test that the package exists."
                Write-Host ""
                Write-Host "Exit codes:"
                Write-Host "  0   Found"
                Write-Host "  1   Not found / package missing"
            }
            default { Write-Host "Unknown command: $Command" }
        }
        return
    }

    Write-Host "Usage: scoopx <binary> [args...]"
    Write-Host "       scoopx --from <package> <binary> [args...]"
    Write-Host "       scoopx shortcut <package>"
    Write-Host "       scoopx listbin <package>"
    Write-Host "       scoopx hasbin [--from <package>] [binary]"
    Write-Host "       scoopx cache [info|purge]"
    Write-Host ""
    Write-Host "Commands:"
    Write-Host "  <bin> [args...]               Run bin (system or package)"
    Write-Host "  --from <pkg> <bin> [args...]  Install and run from package"
    Write-Host "  shortcut <pkg>                  List shortcuts for selection"
    Write-Host "  listbin <pkg>                  List bin entries from manifest"
    Write-Host "  hasbin [--from <pkg>] <bin>    Check if binary exists (exit code only)"
    Write-Host "  cache info                    Show cache usage"
    Write-Host "  cache list                    Show cache usage"
    Write-Host "  cache purge                   Remove all cached packages"
    Write-Host "  cache purge <pkg>             Remove specific package from cache"
    Write-Host "  cache verify                  Check cache integrity"
    Write-Host ""
    Write-Host "Package Formats (--from):"
    Write-Host "  <package>                    Package name (uses cached version if available)"
    Write-Host "  <package@version>            Specific version (e.g. gh@2.7.0)"
    Write-Host "  <package@latest>             Latest version (same as no version)"
    Write-Host "  <url>                        Manifest URL"
    Write-Host "  <path\to\app.json>           Local manifest"
    Write-Host ""
    Write-Host "Scoop Options:"
    Write-Host "  -i, --independent      Don't install dependencies"
    Write-Host "  -k, --no-cache         Don't use download cache"
    Write-Host "  -s, --skip-hash-check  Skip hash validation"
    Write-Host "  -u, --no-update-scoop  Don't update Scoop before install"
    Write-Host "  -a, --arch <arch>      Use specified architecture"
    Write-Host "  --isolated             Don't reuse system scoop's apps/persist/cache"
    Write-Host "  --silent               Suppress output"
    Write-Host "  --keep                 Keep cache dir after run"
    Write-Host "  --verbose              Verbose output"
}

function Get-PackageSpec {
    param([string]$Spec)
    $result = @{ Name = $null; Version = $null; IsUrl = $false; IsPath = $false; Bucket = $null }

    if ($Spec -match '^https?://') {
        $result.IsUrl = $true
        if ($Spec -match '^(.+)@(.+)$') { $result.Name = $Matches[1]; $result.Version = $Matches[2] }
        else { $result.Name = $Spec }
        return $result
    }

    # Handle bucket/pkgname format (e.g., main/7zip, extras/vscode)
    if ($Spec -match '^([^/]+)/([^@/]+)(?:@(.+))?$') {
        $result.Name = $Matches[2]
        $result.Bucket = $Matches[1]
        $v = $Matches[3]
        if ($v -and $v -ne 'latest') { $result.Version = $v }
        return $result
    }

    if ($Spec -match '[\\/]' -or $Spec -match '^[A-Za-z]:') {
        $result.IsPath = $true
        if ($Spec -match '^(.+)@(.+)$') { $result.Name = $Matches[1]; $result.Version = $Matches[2] }
        else { $result.Name = $Spec }
        return $result
    }

    if ($Spec -match '^(.+)@(.+)$') {
        $result.Name = $Matches[1]
        $v = $Matches[2]
        if ($v -ne 'latest') { $result.Version = $v }
    }
    else { $result.Name = $Spec }
    return $result
}

function Detect-Arch {
    param($Manifest)
    if (-not $Manifest) {
        if ([Environment]::Is64BitOperatingSystem) { return '64bit' } else { return '32bit' }
    }

    if ($Manifest.architecture -is [string]) { return $Manifest.architecture }
    if ($Manifest.arch -is [string]) { return $Manifest.arch }

    $archObj = $null
    if ($Manifest.architecture -and $Manifest.architecture -isnot [string]) { $archObj = $Manifest.architecture }
    elseif ($Manifest.arch -and $Manifest.arch -isnot [string]) { $archObj = $Manifest.arch }

    if ($archObj -and $archObj.PSObject.Properties.Count -gt 0) {
        $is64 = [Environment]::Is64BitOperatingSystem
        if ($is64 -and $archObj.'64bit') { return '64bit' }
        elseif (-not $is64 -and $archObj.'32bit') { return '32bit' }
        else { return $archObj.PSObject.Properties[0].Name }
    }

    if ([Environment]::Is64BitOperatingSystem) { return '64bit' } else { return '32bit' }
}

function Install-Package {
    param(
        [string]$PkgSpec,
        [string]$PkgName
    )

    if (-not $SILENT) { Write-Host -NoNewline "`r[scoopx] Installing $PkgName temporarily...                                    " }

    # Find real scoop home
    $scoopReal = $null
    if ($env:SCOOP -and (Test-Path (Join-Path $env:SCOOP 'shims\scoop.cmd'))) {
        $scoopReal = $env:SCOOP
    }
    if (-not $scoopReal) {
        $userScoop = Join-Path $env:USERPROFILE 'scoop'
        if (Test-Path (Join-Path $userScoop 'shims\scoop.cmd')) { $scoopReal = $userScoop }
    }
    if (-not $scoopReal) {
        Write-Host "ERROR: scoop not found. Install: https://scoop.sh"
        return $null
    }

    # Resolve real scoop's download cache dir
    $realCache = $null
    if ($scoopReal) {
        $scoopCfgPath = Join-Path $env:USERPROFILE '.config\scoop\config.json'
        if (Test-Path $scoopCfgPath) {
            try {
                $scoopCfg = Get-Content $scoopCfgPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
                if ($scoopCfg.cache_path) { $realCache = $scoopCfg.cache_path }
            } catch {}
        }
        if (-not $realCache) {
            $candidateCache = Join-Path $scoopReal 'cache'
            if (Test-Path $candidateCache) { $realCache = $candidateCache }
        }
    }

    # Ensure data directories
    New-Item -ItemType Directory -Path (Join-Path $SCOOPX_DATA 'cache') -Force -ErrorAction SilentlyContinue | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $SCOOPX_DATA 'persist') -Force -ErrorAction SilentlyContinue | Out-Null

    # Parse package spec
    $parsed = Get-PackageSpec -Spec $PkgSpec

    # Detect architecture
    $arch = if ($SCOOP_ARCH) { $SCOOP_ARCH } else { 'unknown' }

    # Calculate hash
    $hashInput = "$($parsed.Name)/$($parsed.Version)/$arch"
    $hashBytes = [System.Text.Encoding]::UTF8.GetBytes($hashInput)
    $hash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($hashBytes)) -replace '-',''
    $hash = $hash.Substring(0, 16)

    $cacheDir = Join-Path $SCOOPX_DATA "cache\$hash"
    $cacheIdxPath = Join-Path $SCOOPX_DATA 'index.json'

    # Initialize index
    if (-not (Test-Path $cacheIdxPath)) {
        @{ version = 1; entries = @{} } | ConvertTo-Json -Depth 5 | Set-Content $cacheIdxPath -Encoding UTF8
    }
    $idx = Get-Content $cacheIdxPath -Raw | ConvertFrom-Json
    if (-not $idx.entries) { $idx | Add-Member -NotePropertyName entries -NotePropertyValue @{} -Force }

    # Detect arch and read manifest from real scoop's buckets
    $m = $null
    if ($scoopReal) {
        $realBuckets = Join-Path $scoopReal 'buckets'
        $manifestFile = Get-ChildItem $realBuckets -Recurse -Filter "$($parsed.Name).json" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($manifestFile) { $m = Get-Content $manifestFile.FullName -Raw | ConvertFrom-Json }
    }
    if ($arch -eq 'unknown' -and $m) { $arch = Detect-Arch -Manifest $m }

    # Determine version for hash: @latest uses manifest version, specific version uses that, no version stays null
    $hashVersion = $parsed.Version
    if ((-not $hashVersion) -and $m -and $m.version) {
        if ($PkgSpec -match '@latest$') { $hashVersion = $m.version }
    }

    # Recalculate hash with resolved arch and version
    $hashInput = "$($parsed.Name)/$hashVersion/$arch"
    $hashBytes = [System.Text.Encoding]::UTF8.GetBytes($hashInput)
    $hash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($hashBytes)) -replace '-',''
    $hash = $hash.Substring(0, 16)
    $cacheDir = Join-Path $SCOOPX_DATA "cache\$hash"

    # Check cache hit (skip when --isolated to force fresh install)
    $cacheHit = (-not $ISOLATED) -and (Test-Path $cacheDir) -and (-not $NO_CACHE)

    # Junction real scoop's apps/persist/cache (unless --isolated)
    $cacheApps = Join-Path $cacheDir 'apps'
    $cachePersist = Join-Path $cacheDir 'persist'
    $cacheDownloads = Join-Path $cacheDir 'cache'

    # Always ensure apps dir exists as a plain directory (not junction)
    if (Test-Path $cacheApps) {
        if ((Get-Item $cacheApps).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Remove-Item $cacheApps -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $cacheApps -Force -ErrorAction SilentlyContinue | Out-Null
            if ($VERBOSE) { Write-Host "[verbose] Removed apps junction" }
        }
    } else {
        New-Item -ItemType Directory -Path $cacheApps -Force -ErrorAction SilentlyContinue | Out-Null
    }

    if ($ISOLATED) {
        if ((Test-Path $cachePersist) -and ((Get-Item $cachePersist).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Remove-Item $cachePersist -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $cachePersist -Force -ErrorAction SilentlyContinue | Out-Null
            if ($VERBOSE) { Write-Host "[verbose] Removed persist junction (isolated)" }
        }
        if ((Test-Path $cacheDownloads) -and ((Get-Item $cacheDownloads).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Remove-Item $cacheDownloads -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $cacheDownloads -Force -ErrorAction SilentlyContinue | Out-Null
            if ($VERBOSE) { Write-Host "[verbose] Removed cache junction (isolated)" }
        }
    } else {
        $realApps = Join-Path $scoopReal 'apps'
        $cacheApps = Join-Path $cacheDir 'apps'
        if ((Test-Path $realApps) -and (-not (Test-Path $cacheApps))) {
            New-Item -ItemType Junction -Path $cacheApps -Target $realApps -Force -ErrorAction SilentlyContinue | Out-Null
            if ($VERBOSE) { Write-Host "[verbose] Junctioned apps -> $realApps" }
        }
        $realPersist = Join-Path $scoopReal 'persist'
        $cachePersist = Join-Path $cacheDir 'persist'
        if ((Test-Path $realPersist) -and (-not (Test-Path $cachePersist))) {
            New-Item -ItemType Junction -Path $cachePersist -Target $realPersist -Force -ErrorAction SilentlyContinue | Out-Null
            if ($VERBOSE) { Write-Host "[verbose] Junctioned persist -> $realPersist" }
        }
        if ($realCache -and (Test-Path $realCache) -and (-not (Test-Path $cacheDownloads))) {
            New-Item -ItemType Junction -Path $cacheDownloads -Target $realCache -Force -ErrorAction SilentlyContinue | Out-Null
            if ($VERBOSE) { Write-Host "[verbose] Junctioned cache -> $realCache" }
        }
    }

    if ($cacheHit) {
        if ($VERBOSE) { Write-Host "[verbose] Cache hit: $hash ($($parsed.Name) $arch)" }

        $pkgDir = Join-Path (Join-Path $cacheDir 'apps') $parsed.Name
        $current = Join-Path $pkgDir 'current'
        if (Test-Path $current) {
            $curItem = Get-Item $current -Force -ErrorAction SilentlyContinue
            if ($curItem -and ($curItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                if (-not (Test-Path $current -ErrorAction SilentlyContinue)) {
                    Remove-Item $current -Force -ErrorAction SilentlyContinue
                    $current = $null
                }
            }
        } else {
            $current = $null
        }
        if (-not $current -and (Test-Path $pkgDir)) {
            $verDir = Get-ChildItem $pkgDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'current' } | Select-Object -First 1
            if ($verDir) {
                New-Item -ItemType Junction -Path (Join-Path $pkgDir 'current') -Target $verDir.FullName -Force -ErrorAction SilentlyContinue | Out-Null
            }
        }

        # m is already loaded from real scoop's buckets earlier
    }
    else {
        if ($VERBOSE) { Write-Host "[verbose] Cache miss: $hash ($($parsed.Name) $arch)" }

        # Clean stale package dirs
        $stalePkg = Join-Path $cacheApps $parsed.Name
        if (Test-Path $stalePkg) {
            Remove-Item $stalePkg -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $stalePkg) { cmd /c rmdir /s /q $stalePkg 2>$null }
            if ($VERBOSE) { Write-Host "[verbose] Cleaned stale package dir" }
        }

        # Junction real buckets (for manifest resolution)
        $toolBuckets = Join-Path $cacheDir 'buckets'
        $realBuckets = Join-Path $scoopReal 'buckets'
        if (Test-Path $realBuckets) {
            New-Item -ItemType Directory -Path $toolBuckets -Force -ErrorAction SilentlyContinue | Out-Null
            Get-ChildItem $realBuckets -Directory | ForEach-Object {
                $t = Join-Path $toolBuckets $_.Name
                if (-not (Test-Path $t)) {
                    New-Item -ItemType Junction -Path $t -Target $_.FullName -Force -ErrorAction SilentlyContinue | Out-Null
                }
            }
        }

        # Remove apps junction before scoop install so it installs locally
        if ((Test-Path $cacheApps) -and ((Get-Item $cacheApps).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Remove-Item $cacheApps -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $cacheApps -Force -ErrorAction SilentlyContinue | Out-Null
        }
        # Check if package already installed in real scoop — copy instead of re-downloading
        $realPkgDir = Join-Path (Join-Path $scoopReal 'apps') $parsed.Name
        if (Test-Path $realPkgDir) {
            $hasContent = Get-ChildItem $realPkgDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne 'current' } |
                Select-Object -First 1
            if ($hasContent) {
                if ($VERBOSE) { Write-Host "[verbose] Found in real scoop, will copy to cache dir" }
                $alreadyInstalled = $true
                $LASTEXITCODE = 0
            }
        }
        if (-not $alreadyInstalled) {

        # Build scoop install command
        $scoopArgs = @('install')
        if ($SCOOP_INDEP) { $scoopArgs += '--independent' }
        if ($SCOOP_SKIP_HASH) { $scoopArgs += '--skip-hash-check' }
        if ($SCOOP_NO_UPDATE) { $scoopArgs += '--no-update-scoop' }
        if ($SCOOP_ARCH) { $scoopArgs += '--arch'; $scoopArgs += $SCOOP_ARCH }
        if ($PkgSpec) { $scoopArgs += $PkgSpec } else { $scoopArgs += $PkgName }

        $tmpOut = Join-Path $env:TEMP "scoopx_out_$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
        $origScoop = $env:SCOOP
        $origScoopCache = $env:SCOOP_CACHE
        $origScoopCacheDir = $env:SCOOP_CACHE_DIR
        $origUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $origMachinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $env:SCOOP = $cacheDir
        if ($ISOLATED) {
            $isolatedCache = Join-Path $cacheDir 'cache'
            if (-not (Test-Path $isolatedCache)) {
                New-Item -ItemType Directory -Path $isolatedCache -Force -ErrorAction SilentlyContinue | Out-Null
            }
            $env:SCOOP_CACHE = $isolatedCache
            $env:SCOOP_CACHE_DIR = $isolatedCache
        } else {
            $downloadCacheDir = if ($realCache) { $realCache } else { Join-Path $SCOOPX_DATA 'cache' }
            $env:SCOOP_CACHE = $downloadCacheDir
            $env:SCOOP_CACHE_DIR = $downloadCacheDir
        }
        $scoopCmd = "scoop " + ($scoopArgs -join ' ')
        $proc = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-Command', $scoopCmd) -NoNewWindow -Wait -RedirectStandardOutput $tmpOut -RedirectStandardError "$tmpOut.err" -PassThru
        $env:SCOOP = $origScoop
        $env:SCOOP_CACHE = $origScoopCache
        $env:SCOOP_CACHE_DIR = $origScoopCacheDir
        $currentUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($currentUserPath -ne $origUserPath) {
            [Environment]::SetEnvironmentVariable('Path', $origUserPath, 'User')
            if ($VERBOSE) { Write-Host "[verbose] Restored User PATH (scoop modified it)" }
        }
        $currentMachinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        if ($currentMachinePath -ne $origMachinePath) {
            [Environment]::SetEnvironmentVariable('Path', $origMachinePath, 'Machine')
            if ($VERBOSE) { Write-Host "[verbose] Restored Machine PATH (scoop modified it)" }
        }
        $scoopOutput = @()
        if (Test-Path $tmpOut) { $scoopOutput += Get-Content $tmpOut }
        if (Test-Path "$tmpOut.err") { $scoopOutput += Get-Content "$tmpOut.err" }
        Remove-Item $tmpOut, "$tmpOut.err" -Force -ErrorAction SilentlyContinue
        $scoopOutput | Where-Object { $_ -notmatch 'Copy-Item|shim\.exe' } | Out-Null
        $LASTEXITCODE = $proc.ExitCode

        # If scoop says already installed, copy from real scoop
        $alreadyInstalled = $scoopOutput | Where-Object { $_ -match 'already installed' }
        if ($alreadyInstalled -and $scoopReal) {
            $realPkgDir = Join-Path (Join-Path $scoopReal 'apps') $parsed.Name
            if (Test-Path $realPkgDir) {
                Write-Host "[verbose] Scoop says already installed, will copy from real scoop" -ForegroundColor Cyan
            }
        }
        }

        if ($LASTEXITCODE -eq 0) {
            if ($arch -eq 'unknown' -and $m) { $arch = Detect-Arch -Manifest $m }

            # Update hashVersion from manifest if it was resolved during install
            if ((-not $hashVersion) -and $m -and $m.version) {
                if ($PkgSpec -match '@latest$') { $hashVersion = $m.version }
            }

            $hashInput = "$($parsed.Name)/$hashVersion/$arch"
            $hashBytes = [System.Text.Encoding]::UTF8.GetBytes($hashInput)
            $hash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($hashBytes)) -replace '-',''
            $hash = $hash.Substring(0, 16)
            $correctCacheDir = Join-Path $SCOOPX_DATA "cache\$hash"

            if ($correctCacheDir -ne $cacheDir) {
                if (Test-Path $correctCacheDir) {
                    Remove-Item $cacheDir -Recurse -Force -ErrorAction SilentlyContinue
                    if (Test-Path $cacheDir) { cmd /c rmdir /s /q $cacheDir 2>$null }
                } else {
                    Move-Item $cacheDir $correctCacheDir -Force -ErrorAction SilentlyContinue
                }
                $cacheDir = $correctCacheDir
                $cacheApps = Join-Path $cacheDir 'apps'
                if (-not (Test-Path $cacheApps)) {
                    New-Item -ItemType Directory -Path $cacheApps -Force -ErrorAction SilentlyContinue | Out-Null
                }
            }

            $entry = [ordered]@{
                package = $parsed.Name
                version = $hashVersion
                arch = $arch
                installed = (Get-Date -Format o)
            }
            $idx.entries | Add-Member -NotePropertyName $hash -NotePropertyValue $entry -Force
            $idx | ConvertTo-Json -Depth 5 | Set-Content $cacheIdxPath -Encoding UTF8
            if ($VERBOSE) { Write-Host "[verbose] Cached: $hash ($($parsed.Name) $arch)" }
        }
    }

    # Record env_add
    $envAddPath = Join-Path $cacheDir 'env_add.json'
    if ($m -and $m.env_add) {
        $envAdd = @{}
        foreach ($prop in $m.env_add.PSObject.Properties) { $envAdd[$prop.Name] = $prop.Value }
        $envAdd | ConvertTo-Json -Depth 3 | Set-Content $envAddPath -Encoding UTF8
        if ($VERBOSE) { Write-Host "[verbose] Recorded env_add: $($envAdd.Keys -join ', ')" }
    }

    # If scoop said already installed, copy from real scoop (after all hash calculations)
    if ($alreadyInstalled -and $scoopReal) {
        $realPkgDir = Join-Path (Join-Path $scoopReal 'apps') $parsed.Name
        if (Test-Path $realPkgDir) {
            $currentApps = Join-Path $cacheDir 'apps'
            if (-not (Test-Path $currentApps)) {
                New-Item -ItemType Directory -Path $currentApps -Force -ErrorAction SilentlyContinue | Out-Null
            }
            $destPkgDir = Join-Path $currentApps $parsed.Name
            if (-not (Test-Path $destPkgDir)) {
                Copy-Item $realPkgDir $destPkgDir -Recurse -Force -ErrorAction SilentlyContinue
                $current = Join-Path $destPkgDir 'current'
                $verDir = Get-ChildItem $destPkgDir -Directory | Where-Object { $_.Name -ne 'current' } | Select-Object -First 1
                if ($verDir -and -not (Test-Path $current)) {
                    New-Item -ItemType Junction -Path $current -Target $verDir.FullName -Force -ErrorAction SilentlyContinue | Out-Null
                }
                # Create shims
                $finalBuckets = Join-Path $cacheDir 'buckets'
                $manifest = Get-ChildItem $finalBuckets -Recurse -Filter '*.json' | Select-Object -First 1
                if ($manifest) { $m = Get-Content $manifest.FullName -Raw | ConvertFrom-Json }
                if ($m -and $m.bin) {
                    $raw = @($m.bin)
                    if ($m.bin -is [string]) { $raw = @($m.bin) }
                    foreach ($b in $raw) {
                        $bName = if ($b -is [string]) { $b } else { $b[0] }
                        $shimName = [IO.Path]::GetFileNameWithoutExtension($bName)
                        $src = Join-Path $destPkgDir "current\$shimName.exe"
                        if (-not (Test-Path $src)) { $src = Join-Path $destPkgDir "current\$shimName.cmd" }
                        if (Test-Path $src) {
                            $shimContent = "@echo off", "`"$src`" %*"
                            Set-Content (Join-Path $cacheDir "shims\$shimName.cmd") $shimContent -Encoding ASCII
                        }
                    }
                }
                if ($VERBOSE) { Write-Host "[verbose] Copied from real scoop to cache dir" }
            }
        }
    }

    if (-not $SILENT) { Write-Host -NoNewline "`r[scoopx] Package installed.                                                   " }
    return $cacheDir
}

function Run-WithEnv {
    param(
        [string]$CacheDir,
        [scriptblock]$ScriptBlock
    )

    $env:SCOOP = $CacheDir
    $realCache = $null
    $scoopReal = if ($env:SCOOP_REAL) { $env:SCOOP_REAL } else { $null }
    if (-not $scoopReal) {
        $scoopCfgPath = Join-Path $env:USERPROFILE '.config\scoop\config.json'
        if (Test-Path $scoopCfgPath) {
            try {
                $scoopCfg = Get-Content $scoopCfgPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
                if ($scoopCfg.cache_path) { $realCache = $scoopCfg.cache_path }
                if ($scoopCfg.root_path) { $scoopReal = $scoopCfg.root_path }
            } catch {}
        }
    }
    if (-not $realCache -and $scoopReal) {
        $candidateCache = Join-Path $scoopReal 'cache'
        if (Test-Path $candidateCache) { $realCache = $candidateCache }
    }
    if (-not $realCache) {
        $userScoopCache = Join-Path $env:USERPROFILE 'scoop\cache'
        if (Test-Path $userScoopCache) { $realCache = $userScoopCache }
    }
    if ($ISOLATED) {
        $env:SCOOP_CACHE = Join-Path $CacheDir 'cache'
        $env:SCOOP_CACHE_DIR = Join-Path $CacheDir 'cache'
    } else {
        $downloadCacheDir = if ($realCache) { $realCache } else { Join-Path $SCOOPX_DATA 'cache' }
        $env:SCOOP_CACHE = $downloadCacheDir
        $env:SCOOP_CACHE_DIR = $downloadCacheDir
    }

    $envAddPath = Join-Path $CacheDir 'env_add.json'
    if (Test-Path $envAddPath) {
        $envAdd = Get-Content $envAddPath -Raw | ConvertFrom-Json
        foreach ($k in $envAdd.PSObject.Properties.Name) {
            $val = $envAdd.$k
            if ($val -is [array]) { $val = $val -join ';' }
            [Environment]::SetEnvironmentVariable($k, $val, 'Process')
        }
    }

    if ($VERBOSE) { Write-Host "[verbose] Run-WithEnv: Executing scriptblock" -ForegroundColor Yellow }
    & $ScriptBlock
    if ($VERBOSE) { Write-Host "[verbose] Run-WithEnv: Scriptblock completed, exit: $LASTEXITCODE" -ForegroundColor Yellow }
}

function Invoke-Default {
    if ($script:SCOOP_FROM) {
        Invoke-InstallRun
        return
    }

    # Parse name@version from BIN
    $binName = $BIN
    $pkgSpec = $BIN
    if ($BIN -match '^(.+)@(.+)$') {
        $binName = $Matches[1]
        $pkgSpec = $BIN
    }

    # Try BIN as system command first (only if no @version)
    if (-not ($BIN -match '@')) {
        if ($VERBOSE) { Write-Host "[verbose] Trying Get-Command for '$BIN'" -ForegroundColor Yellow }
        $found = Get-Command $BIN -ErrorAction SilentlyContinue
        if ($found) {
            if ($VERBOSE) { Write-Host "[verbose] Found system cmd: $($found.Source)" -ForegroundColor Yellow }
            if ($VERBOSE) { Write-Host "[verbose] Invoking: & $BIN @BIN_ARGS ($($BIN_ARGS.Count) args)" -ForegroundColor Yellow }
            & $BIN @BIN_ARGS
            if ($VERBOSE) { Write-Host "[verbose] Exit code: $LASTEXITCODE" -ForegroundColor Yellow }
            exit $LASTEXITCODE
        } else {
            if ($VERBOSE) { Write-Host "[verbose] Not found as system command" -ForegroundColor Yellow }
        }
    }

    # Not found as system command: treat as package name, run BIN from package
    $script:SCOOP_FROM = $pkgSpec
    $pkg = $pkgSpec
    $binToRun = $binName

    $cacheDir = Install-Package -PkgSpec $pkg -PkgName $binName
    if (-not $cacheDir) { exit 1 }

    # Try to find and run the binary from the package
    $binPath = $null
    foreach ($ext in @('.cmd', '.exe', '.ps1')) {
        $p = Join-Path $cacheDir "shims\$binToRun$ext"
        if (Test-Path $p) { $binPath = $p; break }
    }
    if (-not $binPath) {
        Get-ChildItem (Join-Path $cacheDir 'apps') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $current = Join-Path $_.FullName 'current'
            if (Test-Path (Join-Path $current "$binToRun.exe")) { $binPath = Join-Path $current "$binToRun.exe" }
        }
    }

    if ($binPath) {
        if ($VERBOSE) { Write-Host "[verbose] Binary: $binPath" -ForegroundColor Yellow }
        if ($VERBOSE) { Write-Host "[verbose] BIN_ARGS count: $($BIN_ARGS.Count)" -ForegroundColor Yellow }
        if ($VERBOSE) { Write-Host "[verbose] BIN_ARGS values: $($BIN_ARGS -join '|')" -ForegroundColor Yellow }
        if (-not $SILENT) { Write-Host "`r[scoopx] Running $binToRun...                                                   " }
        if ($VERBOSE) { Write-Host "[verbose] Calling Run-WithEnv with scriptblock" -ForegroundColor Yellow }
        Run-WithEnv -CacheDir $cacheDir -ScriptBlock { & $binPath @BIN_ARGS }
        if ($VERBOSE) { Write-Host "[verbose] Exit code: $LASTEXITCODE" -ForegroundColor Yellow }
        exit $LASTEXITCODE
    }

    # Binary not found: show list for selection
    Invoke-InstallList
}

function Invoke-InstallList {
    param([string]$PkgName)
    $pkg = if ($PkgName) { $PkgName } else { $script:SCOOP_FROM }

    $parsed = Get-PackageSpec -Spec $pkg
    $pkgName = $parsed.Name

    $cacheDir = Install-Package -PkgSpec $pkg -PkgName $pkgName

    $appDir = Join-Path (Join-Path $cacheDir 'apps') $pkgName
    $items = @()

    # Find manifest from real scoop's buckets
    $scoopReal = $null
    if ($env:SCOOP -and (Test-Path (Join-Path $env:SCOOP 'shims\scoop.cmd'))) { $scoopReal = $env:SCOOP }
    if (-not $scoopReal) {
        $userScoop = Join-Path $env:USERPROFILE 'scoop'
        if (Test-Path (Join-Path $userScoop 'shims\scoop.cmd')) { $scoopReal = $userScoop }
    }

    $m = $null
    if ($scoopReal) {
        $manifest = Get-ChildItem (Join-Path $scoopReal 'buckets') -Recurse -Filter "$pkgName.json" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($manifest) { $m = Get-Content $manifest.FullName -Raw | ConvertFrom-Json }
    }
    # Fallback: try cache dir buckets
    if (-not $m) {
        $manifest = Get-ChildItem (Join-Path $cacheDir 'buckets') -Recurse -Filter "$pkgName.json" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($manifest) { $m = Get-Content $manifest.FullName -Raw | ConvertFrom-Json }
    }

    if ($m) {
        if ($m.bin) {
            $raw = @($m.bin)
            if ($m.bin -is [string]) { $raw = @($m.bin) }
            foreach ($b in $raw) {
                $bName = if ($b -is [string]) { $b } else { $b[0] }
                $bArgs = if ($b -is [string]) { @() } else { $b[1..($b.Length-1)] }
                $bLabel = [IO.Path]::GetFileNameWithoutExtension($bName)
                $items += [PSCustomObject]@{Type='bin'; Label=$bLabel; Exe=$bName; Args=$bArgs; Path=$null}
            }
        }
        if ($m.shortcuts) {
            foreach ($s in $m.shortcuts) {
                $exe = $s[0]; $label = $s[1]
                $exeName = [IO.Path]::GetFileName($exe)
                $src = Join-Path $appDir "current\$exe"
                $items += [PSCustomObject]@{Type='shortcut'; Label=$label; Exe=$exeName; Args=@(); Path=$src}
            }
        }
    }

    if ($items.Count -eq 0) { Write-Host "No bins or shortcuts found for '$pkg'."; exit 1 }

    Write-Host ""
    Write-Host "Contents of ${pkg}:"
    Write-Host ""
    for ($i = 0; $i -lt $items.Count; $i++) {
        $tag = if ($items[$i].Type -eq 'bin') { 'bin' } else { 'shortcut' }
        Write-Host "  [$($i+1)] $($items[$i].Label)  ($($items[$i].Exe)) [$tag]"
    }
    Write-Host ""

    do { $choice = Read-Host 'Select (number or name)' } while (-not $choice)

    $selected = $null
    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $items.Count) {
        $selected = $items[[int]$choice - 1]
    } else {
        $selected = $items | Where-Object { $_.Label -like "*$choice*" -or $_.Exe -like "*$choice*" } | Select-Object -First 1
    }
    if (-not $selected) { Write-Host "Invalid selection."; exit 1 }

    Run-WithEnv -CacheDir $cacheDir -ScriptBlock {
        if ($selected.Type -eq 'bin') {
            $src = Join-Path $appDir "current\$($selected.Exe)"
            if (-not (Test-Path $src)) { $src = Join-Path $cacheDir "shims\$($selected.Label).cmd" }
            & $src $selected.Args
        } else {
            if (Test-Path $selected.Path) { & $selected.Path }
            else { Write-Host "Not found: $($selected.Exe)"; exit 1 }
        }
    }
    exit $LASTEXITCODE
}

function Invoke-InstallRun {
    $pkg = $script:SCOOP_FROM
    $binName = if ($BIN) { $BIN } elseif ($pkg -match '^(.+)@(.+)$') { $Matches[1] } else { $pkg }

    $parsed = Get-PackageSpec -Spec $pkg
    $pkgName = $parsed.Name

    $cacheDir = Install-Package -PkgSpec $pkg -PkgName $binName
    if (-not $cacheDir) { exit 1 }

    # Read manifest to resolve the binary properly
    $scoopReal = $null
    if ($env:SCOOP -and (Test-Path (Join-Path $env:SCOOP 'shims\scoop.cmd'))) { $scoopReal = $env:SCOOP }
    if (-not $scoopReal) {
        $userScoop = Join-Path $env:USERPROFILE 'scoop'
        if (Test-Path (Join-Path $userScoop 'shims\scoop.cmd')) { $scoopReal = $userScoop }
    }

    $m = $null
    if ($scoopReal) {
        $manifestFile = Get-ChildItem (Join-Path $scoopReal 'buckets') -Recurse -Filter "$pkgName.json" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($manifestFile) { $m = Get-Content $manifestFile.FullName -Raw | ConvertFrom-Json }
    }
    if (-not $m) {
        $manifestFile = Get-ChildItem (Join-Path $cacheDir 'buckets') -Recurse -Filter "$pkgName.json" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($manifestFile) { $m = Get-Content $manifestFile.FullName -Raw | ConvertFrom-Json }
    }

    $binPath = $null
    $binArgs = @()

    if ($m -and $m.bin) {
        $raw = @($m.bin)
        if ($m.bin -is [string]) { $raw = @($m.bin) }
        foreach ($b in $raw) {
            $bName = if ($b -is [string]) { $b } else { $b[0] }
            $bLabel = [IO.Path]::GetFileNameWithoutExtension($bName)
            if ($bLabel -ieq $binName -or $bName -ieq $binName -or $bLabel -ieq "$binName.exe" -or $bName -ieq "$binName.exe") {
                $appDir = Join-Path (Join-Path $cacheDir 'apps') $pkgName
                $src = Join-Path $appDir "current\$bName"
                if (Test-Path $src) {
                    $binPath = $src
                    if ($b -isnot [string]) { $binArgs = $b[1..($b.Length-1)] }
                    break
                }
                $src = Join-Path $cacheDir "shims\$bLabel.cmd"
                if (Test-Path $src) {
                    $binPath = $src
                    if ($b -isnot [string]) { $binArgs = $b[1..($b.Length-1)] }
                    break
                }
            }
        }
    }

    # Fallback: search shims and apps directly by name
    if (-not $binPath) {
        foreach ($ext in @('.cmd', '.exe', '.ps1')) {
            $p = Join-Path $cacheDir "shims\$binName$ext"
            if (Test-Path $p) { $binPath = $p; break }
        }
    }
    if (-not $binPath) {
        Get-ChildItem (Join-Path $cacheDir 'apps') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $current = Join-Path $_.FullName 'current'
            if (Test-Path (Join-Path $current "$binName.exe")) { $binPath = Join-Path $current "$binName.exe" }
        }
    }
    # Still not found: fall back to interactive selection (same as non-`--from` path)
    if (-not $binPath) {
        Invoke-InstallList -PkgName $pkgName
        return
    }

    $allArgs = $binArgs + $BIN_ARGS
    if ($VERBOSE) { Write-Host "[verbose] Binary: $binPath" }
    if (-not $SILENT) { Write-Host "`r[scoopx] Running $binName...                                                   " }

    Run-WithEnv -CacheDir $cacheDir -ScriptBlock { & $binPath @allArgs }
    exit $LASTEXITCODE
}

function Invoke-Shortcut {
    $pkg = $script:SCOOP_FROM
    if (-not $pkg) { $pkg = $BIN }
    if (-not $pkg) { Write-Host "ERROR: Usage: scoopx shortcut <package>"; exit 1 }

    $parsed = Get-PackageSpec -Spec $pkg
    $pkgName = $parsed.Name

    $cacheDir = Install-Package -PkgSpec $pkg -PkgName $pkgName
    if (-not $cacheDir) { exit 1 }

    $appDir = Join-Path (Join-Path $cacheDir 'apps') $pkgName
    $items = @()

    # Find manifest from real scoop's buckets
    $scoopReal = $null
    if ($env:SCOOP -and (Test-Path (Join-Path $env:SCOOP 'shims\scoop.cmd'))) { $scoopReal = $env:SCOOP }
    if (-not $scoopReal) {
        $userScoop = Join-Path $env:USERPROFILE 'scoop'
        if (Test-Path (Join-Path $userScoop 'shims\scoop.cmd')) { $scoopReal = $userScoop }
    }

    $m = $null
    if ($scoopReal) {
        $manifest = Get-ChildItem (Join-Path $scoopReal 'buckets') -Recurse -Filter "$pkgName.json" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($manifest) { $m = Get-Content $manifest.FullName -Raw | ConvertFrom-Json }
    }
    if (-not $m) {
        $manifest = Get-ChildItem (Join-Path $cacheDir 'buckets') -Recurse -Filter "$pkgName.json" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($manifest) { $m = Get-Content $manifest.FullName -Raw | ConvertFrom-Json }
    }

    if ($m -and $m.shortcuts) {
        foreach ($s in $m.shortcuts) {
            $exe = $s[0]; $label = $s[1]
            $items += [PSCustomObject]@{Label=$label; Exe=[IO.Path]::GetFileName($exe); Path=Join-Path $appDir "current\$exe"}
        }
    }
    if ($items.Count -eq 0) { Write-Host "No shortcuts found for '$pkg'."; exit 1 }

    Write-Host "`nShortcuts in ${pkg}:`n"
    for ($i = 0; $i -lt $items.Count; $i++) {
        Write-Host "  [$($i+1)] $($items[$i].Label)  ($($items[$i].Exe))"
    }
    Write-Host ""

    do { $choice = Read-Host 'Select (number or name)' } while (-not $choice)

    $selected = $null
    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $items.Count) {
        $selected = $items[[int]$choice - 1]
    } else {
        $selected = $items | Where-Object { $_.Label -like "*$choice*" -or $_.Exe -like "*$choice*" } | Select-Object -First 1
    }
    if (-not $selected) { Write-Host "Invalid selection."; exit 1 }

    Run-WithEnv -CacheDir $cacheDir -ScriptBlock {
        if (Test-Path $selected.Path) { & $selected.Path }
        else { Write-Host "Not found: $($selected.Exe)"; exit 1 }
    }
    exit $LASTEXITCODE
}

function Invoke-ListBin {
    $pkg = $script:SCOOP_FROM
    if (-not $pkg) { $pkg = $BIN }
    if (-not $pkg) { Write-Host "ERROR: Usage: scoopx listbin <package>"; exit 1 }

    $parsed = Get-PackageSpec -Spec $pkg
    $pkgName = $parsed.Name

    # Find manifest from real scoop's buckets (no installation needed)
    $scoopReal = $null
    if ($env:SCOOP -and (Test-Path (Join-Path $env:SCOOP 'shims\scoop.cmd'))) { $scoopReal = $env:SCOOP }
    if (-not $scoopReal) {
        $userScoop = Join-Path $env:USERPROFILE 'scoop'
        if (Test-Path (Join-Path $userScoop 'shims\scoop.cmd')) { $scoopReal = $userScoop }
    }
    if (-not $scoopReal) {
        Write-Host "ERROR: scoop not found. Install: https://scoop.sh"
        exit 1
    }

    $m = $null
    $manifest = Get-ChildItem (Join-Path $scoopReal 'buckets') -Recurse -Filter "$pkgName.json" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($manifest) { $m = Get-Content $manifest.FullName -Raw | ConvertFrom-Json }
    if (-not $m) { Write-Host "ERROR: Package '$pkg' not found in scoop buckets."; exit 1 }

    if ($m.bin) {
        $raw = @($m.bin)
        if ($m.bin -is [string]) { $raw = @($m.bin) }
        foreach ($b in $raw) {
            $bName = if ($b -is [string]) { $b } else { $b[0] }
            $bArgs = if ($b -is [string]) { @() } else { $b[1..($b.Length-1)] }
            $bLabel = [IO.Path]::GetFileNameWithoutExtension($bName)
            $argStr = if ($bArgs.Count -gt 0) { " " + ($bArgs -join ' ') } else { '' }
            Write-Host "  $bLabel  ($bName)$argStr"
        }
    } else {
        Write-Host "No bin entries found for '$pkg'."
    }
    exit 0
}

function Invoke-HasBin {
    $target = $BIN
    $found = $false
    $detail = ''

    if ($script:SCOOP_FROM) {
        # Package mode: check the manifest (no installation performed)
        $pkg = $script:SCOOP_FROM
        $parsed = Get-PackageSpec -Spec $pkg
        $pkgName = $parsed.Name

        $scoopReal = $null
        if ($env:SCOOP -and (Test-Path (Join-Path $env:SCOOP 'shims\scoop.cmd'))) { $scoopReal = $env:SCOOP }
        if (-not $scoopReal) {
            $userScoop = Join-Path $env:USERPROFILE 'scoop'
            if (Test-Path (Join-Path $userScoop 'shims\scoop.cmd')) { $scoopReal = $userScoop }
        }
        if (-not $scoopReal) {
            Write-Host "ERROR: scoop not found. Install: https://scoop.sh"
            exit 1
        }

        $manifestFile = Get-ChildItem (Join-Path $scoopReal 'buckets') -Recurse -Filter "$pkgName.json" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $manifestFile) {
            if (-not $SILENT) { Write-Host "${pkgName}: package not found in scoop buckets" -ForegroundColor Red }
            exit 1
        }
        $m = Get-Content $manifestFile.FullName -Raw | ConvertFrom-Json

        if (-not $target) {
            if (-not $SILENT) { Write-Host "${pkgName}: found (package)" }
            exit 0
        }

        $names = @()
        if ($m.bin) {
            $raw = @($m.bin)
            if ($m.bin -is [string]) { $raw = @($m.bin) }
            foreach ($b in $raw) {
                $bName = if ($b -is [string]) { $b } else { $b[0] }
                $names += [IO.Path]::GetFileName($bName)
                $names += [IO.Path]::GetFileNameWithoutExtension($bName)
            }
        }
        if ($m.shortcuts) {
            foreach ($s in $m.shortcuts) {
                $exe = [IO.Path]::GetFileName($s[0])
                $names += $exe
                $names += [IO.Path]::GetFileNameWithoutExtension($exe)
            }
        }

        foreach ($n in $names) {
            if ($n -ieq $target -or $n -ieq "$target.exe") { $found = $true; break }
        }
        if ($found) { $detail = "package $pkgName" }
    }
    else {
        # System mode: search PATH
        if (-not $target) { Write-Host "ERROR: Usage: scoopx hasbin <binary>"; exit 1 }
        $cmd = Get-Command $target -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) {
            $found = $true
            $detail = if ($cmd.Source) { $cmd.Source } elseif ($cmd.Path) { $cmd.Path } else { 'system' }
        }
    }

    if ($found) {
        if (-not $SILENT) { Write-Host "${target}: found ($detail)" }
        exit 0
    }
    if (-not $SILENT) { Write-Host "${target}: not found" -ForegroundColor Red }
    exit 1
}

function Verify-Cache {
    param([bool]$Fix)

    $idxPath = Join-Path $SCOOPX_DATA 'index.json'
    if (-not (Test-Path $idxPath)) { Write-Host "No cache index found."; return }

    $idx = Get-Content $idxPath -Raw | ConvertFrom-Json
    if (-not $idx.entries -or -not $idx.entries.PSObject.Properties.Name) { Write-Host "Cache index is empty."; return }

    $broken = @()
    $total = 0

    foreach ($key in $idx.entries.PSObject.Properties.Name) {
        $e = $idx.entries.$key
        $cp = Join-Path $SCOOPX_DATA "cache\$key"
        $pkg = if ($e.package) { $e.package } else { $key }
        $issues = @()
        $total++

        # 1. Cache directory existence
        if (-not (Test-Path $cp)) {
            $issues += "cache dir missing"
        } else {
            # 2. Junction targets (apps, persist, buckets, cache)
            foreach ($sub in @('apps', 'persist', 'cache')) {
                $subPath = Join-Path $cp $sub
                if (Test-Path $subPath) {
                    $item = Get-Item $subPath -Force
                    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                        $target = $item.Target
                        if (-not $target -or -not (Test-Path $target)) {
                            $issues += "$sub junction broken -> $target"
                        }
                    }
                }
            }

            # 3. Manifest in buckets
            $manifest = Get-ChildItem (Join-Path $cp 'buckets') -Recurse -Filter '*.json' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $manifest) {
                $issues += "manifest missing"
            } else {
                try { Get-Content $manifest.FullName -Raw | ConvertFrom-Json | Out-Null }
                catch { $issues += "manifest corrupt: $($_.Exception.Message)" }
            }

            # 4. current junction
            $pkgDir = Join-Path (Join-Path $cp 'apps') $pkg
            if (Test-Path $pkgDir) {
                $current = Join-Path $pkgDir 'current'
                if (Test-Path $current) {
                    $item = Get-Item $current -Force
                    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                        $target = $item.Target
                        if (-not $target -or -not (Test-Path $target)) {
                            $issues += "current junction broken -> $target"
                        }
                    }
                } else {
                    $verDir = Get-ChildItem $pkgDir -Directory | Where-Object { $_.Name -ne 'current' } | Select-Object -First 1
                    if ($verDir) { $issues += "current link missing" }
                }
            }

            # 5. env_add.json parseable
            $envAdd = Join-Path $cp 'env_add.json'
            if (Test-Path $envAdd) {
                try { Get-Content $envAdd -Raw | ConvertFrom-Json | Out-Null }
                catch { $issues += "env_add.json corrupt" }
            }
        }

        $verStr = if ($e.version) { $e.version } else { '?' }
        if ($issues.Count -eq 0) {
            Write-Host "  OK   $pkg $verStr [$key]"
        } else {
            Write-Host "  FAIL $pkg $verStr [$key]" -ForegroundColor Red
            foreach ($i in $issues) { Write-Host "       - $i" -ForegroundColor Yellow }
            $broken += @{ Key = $key; Entry = $e; Issues = $issues }
        }
    }

    Write-Host "`nResult: $total checked, $($broken.Count) broken"

    if ($Fix -and $broken.Count -gt 0) {
        Write-Host "`nFixing..."
        foreach ($b in $broken) {
            $cp = Join-Path $SCOOPX_DATA "cache\$($b.Key)"
            if (Test-Path $cp) {
                Remove-Item $cp -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path $cp) { cmd /c rmdir /s /q $cp 2>$null }
                Write-Host "  Removed: $($cp)"
            }
            $idx.entries.PSObject.Properties.Remove($b.Key)
        }
        $idx | ConvertTo-Json -Depth 5 | Set-Content $idxPath -Encoding UTF8
        Write-Host "Fixed $($broken.Count) entries. Index updated."
    } elseif ($broken.Count -gt 0) {
        Write-Host "`nRun 'scoopx cache verify --fix' to remove broken entries."
    }
}

function Invoke-Cache {
    param([string]$Subcommand, [string]$Target)

    $idxPath = Join-Path $SCOOPX_DATA 'index.json'

    if (-not $Subcommand -or $Subcommand -eq 'info' -or $Subcommand -eq 'list') {
        Write-Host "Scoopx Cache:`n  Data dir: $SCOOPX_DATA`n"
        if (-not (Test-Path $idxPath)) { Write-Host "  (no cache)"; return }

        $idx = Get-Content $idxPath -Raw | ConvertFrom-Json
        $totalSize = 0; $count = 0
        if ($idx.entries) {
            foreach ($k in $idx.entries.PSObject.Properties.Name) {
                $e = $idx.entries.$k
                $cp = Join-Path $SCOOPX_DATA "cache\$k"
                $exists = Test-Path $cp
                $size = if ($exists) { (Get-ChildItem $cp -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum } else { 0 }
                $totalSize += $size; $count++
                $status = if ($exists) { 'cached' } else { 'missing' }
                $verStr = if ($e.version) { $e.version } else { '?' }
                $archStr = if ($e.arch) { $e.arch } else { '?' }
                Write-Host "  $($e.package) $verStr $archStr  $([math]::Round($size/1MB,1)) MB  [$status]"
            }
        }
        if ($count -eq 0) { Write-Host "  (no cache)" }
        Write-Host "`nTotal: $count entries, $([math]::Round($totalSize/1MB,1)) MB"
    }
    elseif ($Subcommand -eq 'purge') {
        if (-not (Test-Path $idxPath)) { Write-Host "No cache found."; return }
        $idx = Get-Content $idxPath -Raw | ConvertFrom-Json

        if ($Target) {
            $matched = @()
            foreach ($k in $idx.entries.PSObject.Properties.Name) {
                $e = $idx.entries.$k
                if ($e.package -eq $Target -or $k -eq $Target) {
                    $matched += @{ Key = $k; Entry = $e }
                }
            }
            if ($matched.Count -eq 0) { Write-Host "Package '$Target' not found in cache."; exit 1 }

            foreach ($m in $matched) {
                $cp = Join-Path $SCOOPX_DATA "cache\$($m.Key)"
                $verStr = if ($m.Entry.version) { $m.Entry.version } else { '?' }
                if (Test-Path $cp) {
                    $size = (Get-ChildItem $cp -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                    Remove-Item $cp -Recurse -Force -ErrorAction SilentlyContinue
                    if (Test-Path $cp) { cmd /c rmdir /s /q $cp 2>$null }
                    Write-Host "  Removed $($m.Entry.package) $verStr  ($([math]::Round($size/1MB,1)) MB)"
                } else {
                    Write-Host "  $($m.Entry.package) $verStr  (already missing)"
                }
                $idx.entries.PSObject.Properties.Remove($m.Key)
            }
            $idx | ConvertTo-Json -Depth 5 | Set-Content $idxPath -Encoding UTF8
        } else {
            Write-Host "Purging scoopx cache..."
            $cacheDir = Join-Path $SCOOPX_DATA 'cache'
            $totalSize = 0; $count = 0
            if (Test-Path $cacheDir) {
                Get-ChildItem $cacheDir -Directory | ForEach-Object {
                    $size = (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                    $totalSize += $size; $count++
                    Write-Host "  $($_.Name)  ($([math]::Round($size/1MB,1)) MB)"
                    Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    if (Test-Path $_.FullName) { cmd /c rmdir /s /q $_.FullName 2>$null }
                }
            }
            @{ version = 1; entries = @{} } | ConvertTo-Json -Depth 5 | Set-Content $idxPath -Encoding UTF8
            Write-Host "Purged $count entries ($([math]::Round($totalSize/1MB,1)) MB freed)"
        }
    }
    else {
        Write-Host "Unknown subcommand: $Subcommand"
        Write-Host "Usage: scoopx cache [info|list|purge|verify] [package]"
        exit 1
    }
}

# ============================================================================
# Main entry point
# ============================================================================

# Parse arguments
$SILENT = $false; $NO_CLEANUP = $false; $NO_CACHE = $false
$VERBOSE = $false; $ISOLATED = $false; $CACHE_FIX = $false
$script:SCOOP_FROM = $null; $SCOOP_INDEP = $false; $SCOOP_SKIP_HASH = $false
$SCOOP_NO_UPDATE = $true; $SCOOP_ARCH = $null
$PACKAGE = $null; $BIN = $null; $BIN_ARGS = @()
$SUBCOMMAND = $null; $SUBCOMMAND_ARG = $null

$allArgs = $args
$i = 0
while ($i -lt $allArgs.Count) {
    $arg = $allArgs[$i]
    if ($arg -eq 'cache') { $SUBCOMMAND = 'cache'; $i++; if ($i -lt $allArgs.Count) { $SUBCOMMAND_ARG = $allArgs[$i]; if ($SUBCOMMAND_ARG -notin @('info','list','purge','verify')) { $SUBCOMMAND_ARG2 = $SUBCOMMAND_ARG; $SUBCOMMAND_ARG = 'purge' } else { $i++; if ($i -lt $allArgs.Count) { $SUBCOMMAND_ARG2 = $allArgs[$i]; $i++ } } }; continue }
    if ($arg -eq 'help') { $SUBCOMMAND = 'help'; $i++; if ($i -lt $allArgs.Count) { $SUBCOMMAND_ARG = $allArgs[$i]; $i++ }; continue }
    if ($arg -eq 'shortcut') { $SUBCOMMAND = 'shortcut'; $i++; continue }
    if ($arg -eq 'listbin') { $SUBCOMMAND = 'listbin'; $i++; continue }
    if ($arg -eq 'hasbin') { $SUBCOMMAND = 'hasbin'; $i++; continue }
    if ($arg -eq '--silent' -or $arg -eq '-q') { $SILENT = $true; $i++; continue }
    if ($arg -eq '--keep') { $NO_CLEANUP = $true; $i++; continue }
    if ($arg -eq '--no-cache' -or $arg -eq '-k') { $NO_CACHE = $true; $i++; continue }
    if ($arg -eq '--verbose') { $VERBOSE = $true; $i++; continue }
    if ($arg -eq '--isolated') { $ISOLATED = $true; $i++; continue }
    if ($arg -eq '--fix') { $CACHE_FIX = $true; $i++; continue }
    if ($arg -eq '--help' -or $arg -eq '-h') { Show-Help; exit 0 }
    if ($arg -eq '--independent' -or $arg -eq '-i') { $SCOOP_INDEP = $true; $i++; continue }
    if ($arg -eq '--skip-hash-check' -or $arg -eq '-s') { $SCOOP_SKIP_HASH = $true; $i++; continue }
    if ($arg -eq '--no-update-scoop' -or $arg -eq '-u') { $SCOOP_NO_UPDATE = $true; $i++; continue }
    if ($arg -eq '--arch' -or $arg -eq '-a') { $i++; if ($i -lt $allArgs.Count) { $SCOOP_ARCH = $allArgs[$i]; $i++ }; continue }
    if ($arg -eq '--from') { $i++; if ($i -lt $allArgs.Count) { $script:SCOOP_FROM = $allArgs[$i]; $i++ }; continue }
    if (-not $BIN) { $BIN = $arg; $i++; continue }
    $BIN_ARGS += $arg; $i++
}

if ($VERBOSE) { Write-Host "[verbose] BIN='$BIN'" -ForegroundColor Yellow }
if ($VERBOSE) { Write-Host "[verbose] BIN_ARGS count: $($BIN_ARGS.Count)" -ForegroundColor Yellow }
if ($VERBOSE) { Write-Host "[verbose] BIN_ARGS: $($BIN_ARGS -join '|')" -ForegroundColor Yellow }

# Dispatch
if (-not $SUBCOMMAND -and -not $BIN -and -not $script:SCOOP_FROM) { Show-Help; exit 0 }

switch ($SUBCOMMAND) {
    'cache'    {
        if ($SUBCOMMAND_ARG -eq 'verify') { Verify-Cache -Fix $CACHE_FIX }
        else { Invoke-Cache -Subcommand $SUBCOMMAND_ARG -Target $SUBCOMMAND_ARG2 }
        exit $LASTEXITCODE
    }
    'help'     { Show-Help -Command $SUBCOMMAND_ARG; exit 0 }
    'shortcut' { Invoke-Shortcut; exit $LASTEXITCODE }
    'listbin'  { Invoke-ListBin; exit $LASTEXITCODE }
    'hasbin'   { Invoke-HasBin; exit $LASTEXITCODE }
}

Invoke-Default
