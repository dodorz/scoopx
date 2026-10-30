# scoopx

**`npx` for [Scoop](https://scoop.sh)** — run any Scoop package without permanently installing it.

`scoopx` installs a package into a throwaway, isolated Scoop root, runs the binary you asked for, and cleans up afterwards. Your real Scoop installation is never touched. Installs are cached, so the second run starts instantly.

```
scoopx jq --help
scoopx --from 7zip 7zfm
scoopx mdcat@2.7.0 README.md
```

## Features

- **Run anything on demand** — package name, explicit version, manifest URL, or a local `app.json`.
- **Nothing pollutes your system** — each run gets its own Scoop root under `%LOCALAPPDATA%\scoopx`.
- **Fast repeat runs** — installs are cached by `package/version/arch` hash and reused.
- **Reuses what you already have** — manifests come from your existing buckets, and packages already installed in your real Scoop are copied instead of re-downloaded.
- **Inspection helpers** — `shortcut`, `listbin` and `hasbin` let you discover binaries and use them from scripts.
- **Cache maintenance** — `cache info`, `cache purge`, `cache verify [--fix]`.
- **Single file** — one `.bat` with embedded PowerShell, no dependencies, no install step.

## Requirements

| | |
|---|---|
| OS | Windows 10 / 11 |
| Scoop | installed and working (`scoop` on `PATH`) |
| Shell runtime | PowerShell 5.1 (built in) or PowerShell 7+ (`pwsh`, preferred) |

## Install

### Clone and put it on `PATH` (recommended)

```powershell
git clone https://github.com/dodorz/scoopx.git "$HOME\Tools\scoopx"
$dir = "$HOME\Tools\scoopx"
[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ";$dir", 'User')
```

Open a new terminal and run `scoopx --help`.

### Single file

```powershell
New-Item -ItemType Directory -Force "$HOME\Tools\bin" | Out-Null
Invoke-WebRequest https://raw.githubusercontent.com/dodorz/scoopx/main/scoopx.bat -OutFile "$HOME\Tools\bin\scoopx.bat"
```

Make sure `%USERPROFILE%\Tools\bin` is on your `PATH`.

> Note: the file must keep the name `scoopx.bat` (or be wrapped by a `.cmd` shim that forwards `%*`).

## Usage

```
scoopx <bin> [args...]
scoopx --from <package> <bin> [args...]
scoopx shortcut <package>
scoopx listbin <package>
scoopx hasbin [--from <package>] [binary]
scoopx cache [info|list|purge|verify] [package]
```

### Commands

| Command | Description |
|---|---|
| `<bin> [args...]` | Run a binary. Resolved from `PATH` first, otherwise from the cache. |
| `--from <pkg> <bin> [args...]` | Install `<pkg>` temporarily and run `<bin>` from it. |
| `shortcut <pkg>` | List the shortcuts a package would install, and choose one to run. |
| `listbin <pkg>` | List `bin` entries from the package manifest (no install performed). |
| `hasbin [--from <pkg>] [bin]` | Check whether a binary exists. Prints a result and sets the exit code. |
| `cache info` / `cache list` | Show cached packages and disk usage. |
| `cache purge` | Remove the whole cache. |
| `cache purge <pkg>` | Remove one package from the cache. |
| `cache verify [--fix]` | Check cache integrity; `--fix` deletes broken entries. |
| `help [command]` | Show help for a command. |

### Options

| Option | Description |
|---|---|
| `-i`, `--independent` | Do not install dependencies. |
| `-k`, `--no-cache` | Do not use the download cache. |
| `-s`, `--skip-hash-check` | Skip hash validation. |
| `-u`, `--no-update-scoop` | Do not update Scoop before installing. |
| `-a`, `--arch <arch>` | Force an architecture (`64bit`, `32bit`, `arm64`). |
| `--isolated` | Do not reuse the system Scoop `apps` / `persist` / download cache. |
| `--silent`, `-q` | Suppress progress output. |
| `--keep` | Keep the cache directory after the run. |
| `--verbose` | Verbose diagnostics. |
| `--fix` | With `cache verify`: delete broken entries. |
| `--help`, `-h` | Show help. |

### Package specs (`--from`)

| Form | Meaning |
|---|---|
| `7zip` | Latest version; uses the cached version when one exists. |
| `gh@2.7.0` | Specific version. |
| `gh@latest` | Latest version (same as no version). |
| `https://.../app.json` | Manifest URL. |
| `C:\path\to\app.json` | Local manifest file. |

## Examples

```powershell
# Run a tool once, without installing it
scoopx --from jq jq '.items | length' data.json

# Pin a version
scoopx --from gh@2.7.0 gh --version

# Pick a GUI entry point from a package
scoopx shortcut 7zip

# Discover what a package ships
scoopx listbin 7zip

# Use in scripts: exit code 0 = found, 1 = not found
if (scoopx hasbin git) { 'git available' }
if (scoopx hasbin --from 7zip 7zfm -q) { '7zfm available' }

# Clean up
scoopx cache info
scoopx cache verify --fix
scoopx cache purge
```

## How it works

1. The package spec is normalized and hashed into `package/version/arch` (first 16 hex chars of the SHA-256).
2. A private Scoop root is created at `%LOCALAPPDATA%\scoopx\cache\<hash>`.
3. Directory junctions link your real Scoop `buckets` (for manifest resolution) and — unless `--isolated` is given — its `apps`, `persist` and download cache. A package that is already installed in your real Scoop is copied in instead of downloaded again.
4. `scoop install` runs inside that private root, so it sees the shared buckets without changing your main installation.
5. The requested binary (or shortcut) is executed with your arguments, and its exit code is propagated.
6. The runtime state is cleaned up; the install itself stays cached for the next run.

## Cache

- Location: `%LOCALAPPDATA%\scoopx\cache\<hash>`
- Index: `%LOCALAPPDATA%\scoopx\index.json`
- `--isolated` and `--no-cache` bypass the cache for one run.
- `cache verify` checks directories, junctions (`apps`, `persist`, `cache`, `current`), manifests and `env_add.json`; `--fix` removes broken entries.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success / binary found (`hasbin`) |
| `1` | Failure / binary or package not found (`hasbin`) |
| other | Exit code of the invoked binary |

## Uninstall

```powershell
Remove-Item "$env:LOCALAPPDATA\scoopx" -Recurse -Force   # cache + index
```

Then delete `scoopx.bat` and remove its directory from `PATH`.

## License

[MIT](LICENSE)
