# BawtHub CLI

Install `bh` once on macOS or Linux with Node.js 20+ and npm:

```sh
npm install -g https://github.com/bawthub/bawthub-cli/releases/download/v0.1.1/bawthub-cli-0.1.1.tgz
```

Then, with Docker Desktop (macOS) or Docker Engine and Compose v2 (Linux) running:

```sh
bh install
```

`bh install` uses the release's pinned images and prints the setup URL. The CLI is public; the BawtHub runtime images are private. Use an existing Docker login with read access to the BawtHub images, or run `bh install --bundle /path/to/unpacked-release` if you already have a private release bundle. The CLI does not install Docker, obtain credentials, or require a Git checkout.

Run `bh status`, `bh stop`, `bh start`, `bh restart` or `bh logs` from any directory. Stopping does not remove data. `bh setup` opens the installer menu; `bh --help` lists other commands. New installs default to `${XDG_DATA_HOME:-$HOME/.local/share}/bawthub/tenant` and get their own Docker project and volumes, leaving older installations alone. New installs use port 3000 when free, or the next available port through 3020. The installer prints the URL; existing CLI installs keep their saved port.

To prepare a CLI release from a committed revision, run `bash deploy/pack-cli.sh FULL_COMMIT_SHA OUTPUT_DIRECTORY`. The npm archive contains the CLI and pinned installer inputs, not the runtime images.

Licensed under [Elastic License 2.0](LICENSE).
