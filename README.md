# BawtHub CLI

Install `bh` once on macOS or Linux with Node.js 20+ and npm:

```sh
npm install -g https://github.com/bawthub/bawthub-cli/releases/download/v0.1.6/bawthub-cli-0.1.6.tgz
```

Then, with Docker Desktop (macOS) or Docker Engine and Compose v2 (Linux) running:

```sh
bh install
```

`bh install` uses the release's pinned images and prints the setup URL. The CLI is public; the BawtHub runtime images are private. Use an existing Docker login with read access to the BawtHub images, or run `bh install --bundle /path/to/unpacked-release` if you already have a private release bundle. The CLI does not install Docker, obtain credentials, or require a Git checkout.

Run `bh status`, `bh stop`, `bh start`, `bh restart` or `bh logs` from any directory. Stopping does not remove data. `bh setup` opens the installer menu; `bh --help` lists other commands. New installs default to `${XDG_DATA_HOME:-$HOME/.local/share}/bawthub/tenant` and get their own Docker project and volumes, leaving older installations alone. New installs use port 3000 when free, or the next available port through 3020. The installer prints the URL; existing CLI installs keep their saved port.

`bh status` groups services by purpose and shows the web port and anything that needs attention. It checks the Web UI, API and bundled Voice API health endpoints from inside the selected tenant's containers and reports Docker health for other services. A running service with no health check is not labeled healthy. Status does not start or change any services.

Run `bh version` to see the CLI, installed stack revision, and versions of this tenant’s running or stopped services. It compares image digests against the latest BawtHub release, not against upstream registries. Custom pins and images that BawtHub doesn’t track are labeled separately. `bh version --offline` lists installed versions without contacting GitHub; `bh --version` still prints just the CLI version. Neither command pulls images or restarts services.

Run `bh chat "message"` to talk to your default bot from the terminal, or `bh chat -b BOT` for another one. Replies stream as they're written, and agent bots that queue their reply are waited for. Each message continues the same conversation you see in the web app. With no message, `bh chat` reads a piped message or starts an interactive chat. `bh chat --history 10` prints recent messages, and `bh chat --help` lists the other options (`-m` model, `-u` user, `--plain`, `--no-stream`, `-c` to include a command's output). `bh jobs` shows scheduled background jobs and recent runs, `bh jobs run TYPE` runs one now, and `bh status --service` shows the API's own status. These commands use the running installation's local API port and need no extra login.

Run `bh update` to download a newer CLI release, if one is available, and then update BawtHub with that release's installer. `bh update --bundle DIR` uses the local bundle without checking for a new CLI. Installs and updates show image and service progress by default; add `--verbose` for Docker layer details.

To prepare a CLI release from a committed revision, run `bash deploy/pack-cli.sh FULL_COMMIT_SHA OUTPUT_DIRECTORY`. The npm archive contains the CLI and pinned installer inputs, not the runtime images.

Licensed under [Elastic License 2.0](LICENSE).
