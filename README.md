# SuperUp

Start your local web apps from the macOS menu bar.

SuperUp shows how many of your configured apps are healthy. Click an app to
open it in your browser. If its server is stopped, SuperUp starts it first,
waits for a healthy response, then opens the page.

For example, keep your frontend and a local dashboard in the menu instead of
finding their terminal tabs and remembering their ports.

**Early version (0.1.0).** Native Swift and AppKit, no third-party dependencies.
Built for developers who are comfortable editing a small JSON file.

## Install from source

- macOS 13 or later.
- Swift 5.10 or later, with Apple's Command Line Tools or Xcode selected by
  `xcode-select`. Check your compiler with `swift --version`.
- Your apps' own runtimes and dependencies installed separately.

Clone or download this repository, open its directory in Terminal, then run:

```sh
./scripts/install-app.sh
```

This builds `build/SuperUp.app`, installs it at `~/Applications/SuperUp.app`,
and opens it. Quit SuperUp from its menu before reinstalling; quitting also
stops servers it owns. Use `./scripts/build-app.sh` to build without installing.

The build targets your Mac's architecture and uses an **ad hoc signature**.
It is intended for local builds, not a notarized download for other Macs.

## Add your first app

The first launch creates an empty config folder. Choose **Open Config Folder**
from the menu, then save a file such as `my-app.json` inside it:

```json
{
  "name": "My App",
  "directory": "~/Sites/my-app",
  "command": "npm run dev -- --host 127.0.0.1 --port 5177 --strictPort",
  "url": "http://127.0.0.1:5177"
}
```

This example assumes a Vite app. Change the directory and command to match
your project, choose **Reload Configs**, then click **My App**.
See [examples/vite.json](examples/vite.json) and
[examples/nextjs.json](examples/nextjs.json) for editable templates.
Examples are never installed automatically, and upgrades preserve your configs.

Configs live in `~/Library/Application Support/SuperUp/apps/`, one JSON file
per app. The filename without `.json` is the app ID.

| Field | Required | Meaning |
| --- | --- | --- |
| `name` | Yes | Label in the menu. |
| `directory` | Yes | Existing working directory; `~` expands to your home. |
| `command` | Yes | Shell command that starts a foreground server. |
| `url` | Yes | Local HTTP URL to open in the browser. |
| `healthURL` | No | URL to probe; defaults to `url`, and must share its origin. |
| `expectedText` | No | Text that must appear in the health response. |

Use `localhost` or `127.0.0.1`, with a different port for each app. Health
checks require a 2xx response. If another service might use the same port,
set `expectedText` to a distinctive part of your page, such as its title.
Invalid configs appear in the menu with an explanation.

Commands run through an interactive login `zsh`, so your shell setup can load
tools such as nvm. Config files execute commands with your user permissions;
review configs before using ones supplied by someone else. Keep server
commands in the foreground and avoid interactive prompts or password requests.

## Daily use

- **Click an app:** check its health, start it if needed, then open its URL.
- **Stop:** stop a server started by SuperUp.
- **View Log:** open that app's current log.
- **Reload Configs:** apply added or edited JSON files. Removing or changing a
  config stops its SuperUp-owned server; click it again to start the new config.
- **Launch at Login:** click to enable or disable. Off by default on new
  installations; an existing login registration is preserved. Available when
  installed at `~/Applications/SuperUp.app`. macOS may require approval in
  **Open Login Items Settings**.
- **Quit:** stop SuperUp-owned servers and exit. Externally started servers
  are left running.

Starting SuperUp, including at login, does not automatically start any server.
After you start one through the menu, SuperUp checks it every three seconds
and restarts it after an unexpected exit or repeated failed health checks.
Repeated start failures back off to a maximum delay of one minute.

## Logs and troubleshooting

Logs live in `~/Library/Logs/SuperUp/`. Each app has a current `<id>.log` and
at most one `<id>.log.1` archive. SuperUp checks log size before starting a
server and every three seconds while it runs. At 5 MiB it saves the newest
5 MiB to the archive, replacing the previous archive, and truncates the
current file without restarting the server.

This is a soft size limit: output can exceed it between checks. Rotation uses
copy/truncate, so output written during rotation can be lost. These are local
debugging logs, not an audit trail. If rotation fails, it stops for that process
and reports an error in macOS Console; logs can then keep growing.

- **Directory does not exist:** edit `directory`, then reload configs.
- **Server never becomes healthy:** inspect its log, check the port, and run
  its command from the configured directory in Terminal. Check `healthURL`
  and `expectedText` too. Servers taking over a minute to start may be restarted.
- **Running externally:** the server was started elsewhere. Stop it from its
  original terminal if you want SuperUp to start and manage it.
- **Command not found:** check that the tool is available in `zsh -lic` and
  that your shell configuration works without a terminal attached.

## Development

```sh
./scripts/check.sh
./scripts/build-app.sh
```

Checks cover an empty first launch, config preservation and validation, log
rotation with an open writer, health responses, server startup and crash
recovery, port collisions, and leaving external servers running. They use
`/usr/bin/python3` for temporary HTTP fixtures and require permission to bind
loopback ports. No personal app config is used by the checks.

GitHub Actions runs the checks and verifies the built bundle on macOS 15 for
Apple Silicon and Intel. Native menu behavior and login-item approval still
need manual verification. CI does not cover macOS 13.

Small fixes and focused pull requests are welcome. Include reproduction steps
for bugs and run the checks before proposing behavior changes.

## Uninstall

1. Turn **Launch at Login** off, then choose **Quit SuperUp**.
2. Delete `~/Applications/SuperUp.app`.
3. To remove saved configs and logs as well, delete
   `~/Library/Application Support/SuperUp/` and `~/Library/Logs/SuperUp/`.
   Keep these folders if you plan to reinstall.

## License

[MIT](LICENSE) © 2026 Piotr Kacała.
