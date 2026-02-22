# GetSymi

Install scripts for [Symi](https://github.com/symi/symi), served via GitHub Pages.

## Quick Start

### macOS / Linux / WSL

```bash
curl -fsSL https://jaysteelmind.github.io/getsymi/install.sh | bash
```

### Windows (PowerShell)

```powershell
iwr -useb https://jaysteelmind.github.io/getsymi/install.ps1 | iex
```

### Local prefix install (no root)

```bash
curl -fsSL https://jaysteelmind.github.io/getsymi/install-cli.sh | bash
```

## Scripts

| Script | Platform | Description |
|--------|----------|-------------|
| `install.sh` | macOS / Linux / WSL | Installs Node if needed, installs Symi via npm or git |
| `install-cli.sh` | macOS / Linux / WSL | Self-contained install to `~/.symi` with local Node runtime |
| `install.ps1` | Windows (PowerShell 5+) | Installs Node if needed, installs Symi via npm or git |

## Documentation

See the [Symi installer docs](https://docs.symi.ai/install/installer) for full flag and environment variable references.
