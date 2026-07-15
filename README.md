# EZJiboServer

A simple, one-command way to install and run
[JiboExperiments/OpenJibo](https://github.com/Jibo-Revival-Group/JiboExperiments).

Tested to work on:
- Arch Linux
- Ubuntu (24)

`setup.sh` is a self-contained installer designed to be run straight from the
internet. It installs the toolchain, clones the repo into `~/EZJiboServer`,
writes a ready-to-use `.env`, generates self-signed TLS certificates for
live/device mode, warms up the build, and leaves behind two scripts:

- `run.sh` - start the OpenJibo server
- `update.sh` - pull the latest JiboExperiments

`setup.sh` itself is not left in the install directory - only `run.sh` and
`update.sh` are.

## Install
```bash
curl -fsSL https://raw.githubusercontent.com/Jibo-Revival-Group/EZJiboServerGit/refs/heads/master/setup.sh | bash
```

If you have the file locally instead, just run `./setup.sh`.

## Run
```bash
cd ~/EZJiboServer
./run.sh          # live/device mode on port 443 (default, uses sudo)
./run.sh local    # local dev cloud instead
```

For local testing, open the health check at <http://localhost:24605/health>.

## What setup.sh installs

It auto-detects your package manager (`pacman`, `apt`, `dnf`, or Homebrew) and
installs anything missing:

- **.NET 10 SDK** - via your package manager, else the official
  `dotnet-install.sh` into `~/.dotnet`
- **PowerShell (`pwsh`)** - via your package manager, else the official GitHub
  release tarball into `~/.powershell`
- **openssl**, **ffmpeg**, **git**, and a **C/C++ build toolchain** + **cmake**
- **whisper.cpp** - built from source into `~/EZJiboServer/whisper.cpp`, plus the
  `ggml-base.en` model (used for local speech-to-text)

It then:

1. Clones `JiboExperiments` into `~/EZJiboServer/JiboExperiments`.
2. Creates `JiboExperiments/OpenJibo/.env` from `.env.example`, generating fresh
   `OPENJIBO_USER_ENCRYPT` / `OPENJIBO_USER_SALT` and wiring the whisper/ffmpeg
   STT paths. An existing `.env` is never overwritten (it holds your encryption
   keys).
3. Generates self-signed TLS certificates in `~/EZJiboServer/certs/` with SANs
   for `api.jibo.com`, `api-socket.jibo.com`, `neo-hub.jibo.com`, `localhost`,
   and `127.0.0.1` (used by live/device mode).
4. Runs a `dotnet restore` + `build` warm-up so the first run is fast.

### setup.sh options

```
./setup.sh --home DIR      # install somewhere other than ~/EZJiboServer
./setup.sh --skip-deps     # only verify system dependencies
./setup.sh --skip-whisper  # don't build whisper.cpp / download a model
./setup.sh --skip-build    # skip the dotnet restore/build warm-up
./setup.sh --skip-certs    # don't generate TLS certificates
./setup.sh --force-certs   # regenerate TLS certificates even if present
./setup.sh -y              # non-interactive
```

## Running the server

```bash
./run.sh            # live-device mode on port 443 (real Jibo) [default]
./run.sh live       # same as above
./run.sh local      # local dev cloud (https://localhost:24604 / http://localhost:24605)
```

- **live** (default) binds port `443` with TLS so a physical Jibo can connect. It
  uses the self-signed certificates in `~/EZJiboServer/certs/` by default,
  converts them to a PFX for Kestrel via the repo's
  `scripts/cloud/start-dotnet-with-node-cert.sh`, and runs with `sudo` for the
  privileged port. To use your own certificate material instead:

  ```bash
  CERT_PEM=/path/to/cert.pem KEY_PEM=/path/to/key.pem ./run.sh live
  ```

- **local** starts on `https://localhost:24604` and `http://localhost:24605`
  (health at `/health`). No certificates or root needed. This is the best mode
  for testing.

Both modes use fully local, file-backed persistence (under `OpenJibo/App_Data`)
so no external services are required. `run.sh` also does a `git pull` to update
OpenJibo before starting; skip it with `./run.sh --no-update` (or `NO_UPDATE=1`).

  Use the same certificate material your Jibo routing already trusts. See the
  repo's `docs/device-bootstrap.md` for the device side.

## Updating

```bash
./update.sh              # git pull + dotnet restore
./update.sh --no-restore # pull only
```

## Layout after setup

```
~/EZJiboServer/
  run.sh                 # generated
  update.sh              # generated
  certs/                 # generated self-signed TLS certs
  whisper.cpp/           # locally built STT engine + model
  JiboExperiments/       # cloned upstream repo
    OpenJibo/
      .env               # generated (secrets + STT paths)
      ...
```

## Notes

- The default state backend is file-based, so **no Docker or Postgres** is
  required for local runs.
- Speech-to-text (whisper) is optional at runtime - the server still starts
  without it - but it is installed by default so real audio works.
- Override the install location any time with `EZJIBOSERVER_HOME` or `--home`.

## Troubleshooting

- **`NETSDK1226: Prune Package data not found ... Microsoft.AspNetCore.App`** -
  distro-packaged .NET 10 SDKs (notably Arch) ship the AspNetCore shared
  framework without the new prune-package data. All EZJiboServer scripts export
  `AllowMissingPrunePackageData=true` to work around this automatically. If you
  run `dotnet` by hand, set that variable too (or install the SDK via
  `dotnet-install.sh`, which includes the data).

## Repo contents

This repository is just the installer source. The distributable artifact is
`setup.sh`; `run.sh` and `update.sh` are generated by it (embedded as heredocs
inside `setup.sh`), so edit them there.
