<#
.SYNOPSIS
    Symi installer for Windows (PowerShell 5+)
.DESCRIPTION
    Installs Symi on Windows. Ensures Node.js 22+ is available (via winget,
    Chocolatey, or Scoop), then installs Symi via npm (default) or git.
.LINK
    https://docs.symi.ai/install/installer
.EXAMPLE
    iwr -useb https://jaysteelmind.github.io/getsymi/install.ps1 | iex
.EXAMPLE
    & ([scriptblock]::Create((iwr -useb https://jaysteelmind.github.io/getsymi/install.ps1))) -InstallMethod git
#>
[CmdletBinding()]
param(
    [ValidateSet("npm", "git")]
    [string]$InstallMethod = $(if ($env:SYMI_INSTALL_METHOD) { $env:SYMI_INSTALL_METHOD } else { "npm" }),

    [string]$Tag = "latest",

    [string]$GitDir = $(if ($env:SYMI_GIT_DIR) { $env:SYMI_GIT_DIR } else { "$env:USERPROFILE\symi" }),

    [switch]$NoOnboard,

    [switch]$NoGitUpdate,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$NodeMinVersion = 22

# ── Helpers ──────────────────────────────────────────────────────────────
function Write-Info  { param([string]$Msg) Write-Host "[info]  $Msg" -ForegroundColor Blue }
function Write-Warn  { param([string]$Msg) Write-Host "[warn]  $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "[error] $Msg" -ForegroundColor Red }

function Test-Command { param([string]$Name) $null -ne (Get-Command $Name -ErrorAction SilentlyContinue) }

function Get-NodeMajor {
    if (-not (Test-Command "node")) { return 0 }
    $ver = & node --version 2>$null
    if ($ver -match '^v?(\d+)') { return [int]$Matches[1] }
    return 0
}

# ── Check PowerShell version ────────────────────────────────────────────
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Err "PowerShell 5+ required. Current: $($PSVersionTable.PSVersion)"
    exit 1
}

# Apply env var overrides
if ($env:SYMI_NO_ONBOARD -eq "1") { $NoOnboard = $true }
if ($env:SYMI_GIT_UPDATE -eq "0") { $NoGitUpdate = $true }
if ($env:SYMI_DRY_RUN -eq "1")    { $DryRun = $true }

Write-Info "Symi installer — method=$InstallMethod tag=$Tag"

# ── Step 1: Ensure Node.js 22+ ──────────────────────────────────────────
function Install-Node {
    $major = Get-NodeMajor
    if ($major -ge $NodeMinVersion) {
        Write-Info "Node.js v$major found — OK"
        return
    }

    Write-Info "Node.js $NodeMinVersion+ required — installing..."

    # Try winget
    if (Test-Command "winget") {
        Write-Info "Installing Node via winget..."
        if (-not $DryRun) {
            winget install OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements 2>$null
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                        [System.Environment]::GetEnvironmentVariable("Path", "User")
        } else {
            Write-Info "[dry-run] winget install OpenJS.NodeJS.LTS"
        }
        if ((Get-NodeMajor) -ge $NodeMinVersion) { return }
    }

    # Try Chocolatey
    if (Test-Command "choco") {
        Write-Info "Installing Node via Chocolatey..."
        if (-not $DryRun) {
            choco install nodejs-lts -y 2>$null
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                        [System.Environment]::GetEnvironmentVariable("Path", "User")
        } else {
            Write-Info "[dry-run] choco install nodejs-lts -y"
        }
        if ((Get-NodeMajor) -ge $NodeMinVersion) { return }
    }

    # Try Scoop
    if (Test-Command "scoop") {
        Write-Info "Installing Node via Scoop..."
        if (-not $DryRun) {
            scoop install nodejs-lts 2>$null
        } else {
            Write-Info "[dry-run] scoop install nodejs-lts"
        }
        if ((Get-NodeMajor) -ge $NodeMinVersion) { return }
    }

    Write-Err "Could not install Node.js $NodeMinVersion+. Install manually from https://nodejs.org"
    exit 1
}

# ── Step 2: Ensure Git ──────────────────────────────────────────────────
function Ensure-Git {
    if (Test-Command "git") { return }
    if ($InstallMethod -eq "git") {
        Write-Err "Git is required for git install method. Install from https://git-scm.com/download/win"
        exit 1
    }
    Write-Warn "Git not found. Some npm packages may fail without Git."
}

# ── Step 3: Install Symi via npm ─────────────────────────────────────────
function Install-SyMiNpm {
    Write-Info "Installing @symerian/symi@$Tag via npm..."
    if ($DryRun) {
        Write-Info "[dry-run] npm install -g @symerian/symi@$Tag"
        return
    }
    & npm install -g "@symerian/symi@$Tag"
    if ($LASTEXITCODE -ne 0) {
        Write-Err "npm install failed with exit code $LASTEXITCODE"
        exit 1
    }
}

# ── Step 4: Install Symi via git ─────────────────────────────────────────
function Install-SyMiGit {
    Write-Info "Installing Symi from source into $GitDir..."
    if ($DryRun) {
        Write-Info "[dry-run] Would clone/update and build symi in $GitDir"
        return
    }

    if (Test-Path "$GitDir\.git") {
        if (-not $NoGitUpdate) {
            Write-Info "Updating existing checkout..."
            & git -C $GitDir pull --ff-only
        }
    } else {
        & git clone https://github.com/symi/symi.git $GitDir
    }

    Push-Location $GitDir
    try {
        if (-not (Test-Command "pnpm")) {
            Write-Info "Installing pnpm..."
            & npm install -g pnpm
        }
        & pnpm install
        & pnpm run build

        # Create wrapper
        $binDir = "$env:USERPROFILE\.local\bin"
        New-Item -ItemType Directory -Force -Path $binDir | Out-Null
        $wrapperContent = "@echo off`r`nnode `"$GitDir\dist\index.js`" %*"
        Set-Content -Path "$binDir\symi.cmd" -Value $wrapperContent

        # Add to user PATH
        Add-ToUserPath $binDir
        Write-Info "Symi installed to $binDir\symi.cmd"
    } finally {
        Pop-Location
    }
}

# ── PATH helper ──────────────────────────────────────────────────────────
function Add-ToUserPath {
    param([string]$Dir)
    $currentPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    if ($currentPath -notlike "*$Dir*") {
        $newPath = "$currentPath;$Dir"
        [System.Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        $env:Path = "$env:Path;$Dir"
        Write-Info "Added $Dir to user PATH"
    }
}

# ── Step 5: Add npm bin to PATH ──────────────────────────────────────────
function Ensure-NpmBinInPath {
    if ($InstallMethod -ne "npm") { return }
    $npmPrefix = & npm config get prefix 2>$null
    if ($npmPrefix) {
        $npmBin = Join-Path $npmPrefix "bin"
        # On Windows, npm global installs go directly into prefix (no /bin)
        if (-not (Test-Path $npmBin)) { $npmBin = $npmPrefix }
        Add-ToUserPath $npmBin
    }
}

# ── Step 6: Post-install ─────────────────────────────────────────────────
function Post-Install {
    if ($DryRun) {
        Write-Info "[dry-run] Would run post-install checks"
        return
    }

    if (-not (Test-Command "symi")) {
        # Refresh PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path", "User")
    }

    if (Test-Command "symi") {
        Write-Info "Running symi doctor..."
        & symi doctor --non-interactive 2>$null
    } else {
        Write-Warn "symi not found in PATH. Reopen PowerShell and try again."
        Write-Warn "Tip: npm config get prefix — add that directory to PATH."
    }

    if (-not $NoOnboard -and (Test-Command "symi")) {
        Write-Info "Starting onboarding..."
        & symi onboard --install-daemon 2>$null
    }
}

# ── Main ─────────────────────────────────────────────────────────────────
Install-Node
Ensure-Git
if ($InstallMethod -eq "npm") {
    Install-SyMiNpm
    Ensure-NpmBinInPath
} else {
    Install-SyMiGit
}
Post-Install
Write-Info "Done! Run 'symi' to get started."
