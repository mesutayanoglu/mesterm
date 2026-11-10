# MesTerm

MesTerm is based on [CommandS](https://github.com/emrhn0/CommandS) by emrhn0, used and developed further with the author's permission.

A native SSH/RDP connection manager for Windows and macOS. No
WebView: built with Flutter, rendered natively.

## Features

- Full folder tree always visible on the left, collapsed by default,
  virtualized for large lists. Add connections through a popup dialog, not
  an always-open form.
- SSH sessions run through **OpenSSH** (the client Windows ships, or the
  system `ssh` on macOS), inside a real pseudo-terminal (ConPTY on
  Windows) rendered by our own [xterm.dart](https://pub.dev/packages/xterm)
  view — not a hand-rolled SSH client. Network gear (Cisco, Aruba, older
  firmware) negotiates auth methods and algorithms a young pure-Dart client
  trips over; OpenSSH handles them, with legacy algorithms enabled only as
  a fallback. The terminal size follows the pane (split view included), and
  the keyboard behaves as in PuTTY: arrow-key history, Ctrl+A/Ctrl+V sent to
  the session, Shift+Insert paste, select-to-copy, right-click paste.
- Serial consoles (a network device's console cable): the quick connect box defaults
  to **Serial** — type the COM port number (`3` for COM3, `3:115200` for
  another speed; 9600 8N1 otherwise). The port is opened by the app itself,
  so keys reach the device as typed. macOS uses the system `screen` on the
  `/dev` device.
- The connection tree works like Windows Explorer: a click selects, a double
  click connects (or opens a folder); Ctrl/Shift select several. Drag
  connections and folders into any folder, or onto a folder's top or bottom
  edge to put folders in your own order. Drag the panel's right edge to
  widen it.
- Terminal colours from swatches, a colour code, or a palette (saturation
  square and hue bar) that fills in the code.
- Tabbed sessions — each tab is independent and live; switching tabs never
  drops the connection. Right-click a tab to reconnect it, or to save a
  quick connection. Split view shows several sessions side by side as one
  tab.
- RDP sessions on Windows are drawn **inside a tab**, through Microsoft's own
  Remote Desktop ActiveX control (`mstscax.dll`) hosted in-process — the same
  engine `mstsc.exe` is a shell over, so fidelity, input and performance are
  the real client's. Credentials go straight to the control (nothing is
  written to Windows Credential Manager), there is no `.rdp` file and so no
  "unknown publisher" warning, and resizing a pane renegotiates the remote
  desktop at its exact pixel size instead of stretching the old one.
  Ctrl+Alt+Del can be sent from the session bar.
- RDP on macOS opens in the best client installed. FreeRDP
  (`brew install freerdp`) is preferred and is handed the whole connection
  including the saved password, so nothing is typed; otherwise the Microsoft
  client ("Windows App", or the older "Microsoft Remote Desktop") is launched
  with the host and username filled in, and the tab offers the password for
  pasting. Either way the session is its own window: macOS has no embeddable
  RDP component, and AppKit does not let one app place another app's window
  inside its own, so drawing the session in the tab means speaking RDP
  in-process — planned, not here yet.
- PuTTY-style in-terminal `login as:` / `password:` prompts when a
  connection is opened with host only.
- Folder-organized saved connections (create/rename/delete folders;
  deleting a folder keeps its connections, just unfiled). Multi-select
  with Ctrl/Shift-click for bulk move/delete, and cloning a connection.
- Import your own JSON/XML/CSV export, or an export from other popular
  connection managers (nested groups become folders; some of those tools
  encrypt saved passwords with their own vault key that can't be
  decrypted from the exported file alone and must be re-entered — a CSV
  export with credentials visible, where the source tool offers one,
  carries them across intact).
- Customizable terminal colors, saved per install.
- Monochrome, sharp-edged theme — black on white in light mode, white on black in dark mode.

## ChatGPT Work (MCP)

In **Settings > MCP integration**, turn on MCP access and copy the displayed
URL. MesTerm listens only on `127.0.0.1:8765`; the random path in the URL is
a secret, so keep the full URL private. The server is off by default and
remembers the setting across launches.

- **ChatGPT Work desktop:** add a local Streamable HTTP MCP server using the
  displayed URL.
- **Hosted ChatGPT Work:** run an [OpenAI Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)
  on the same computer, targeting the displayed URL, then connect its tunnel
  ID to a private ChatGPT Work plugin. The desktop app and tunnel must be
  running for commands to reach MesTerm.

When MCP access is on, the agent sees the whole app: every saved connection
(name, folder, protocol, host, port, device kind), every open tab and every
terminal. Usernames and passwords are never in a tool result.

Commands are checked from both sides. With each command the agent says
whether it only reads (`intent: "read"`) or changes something
(`intent: "change"`), and MesTerm checks the command itself:

- It runs at once only when the agent calls it a read **and** MesTerm knows
  it as read-only: `show`, `display`, `get`, `ping`, `traceroute`, filters
  after `|` such as `include` or `grep`, and read-only Linux and Windows
  commands (`ls`, `cat`, `ip a`, `systemctl status`, `ipconfig /all`...).
- Anything else asks you in MesTerm first: a change, a command MesTerm does
  not know, anything chained or redirected (`;`, `&&`, `>`, backticks), and
  any command typed at a configuration prompt (`(config)#`, `[edit]`,
  Huawei system-view, Fortinet `(...) #`). No answer within two minutes is
  a no.
- **Settings > MCP integration > Ask before every command** makes reads ask
  too.

At initialize MesTerm gives the agent short working rules (`McpServer.serverInstructions`): filter `list_connections`; run 1-2 commands directly; for 3 or more, plan and interpret while one subagent (Haiku, where the client supports it) runs read-only commands one by one and returns their raw output; configuration changes only by the main model, after the user approves them.

The tools:

- `list_connections`: filters `folder`, `query` (name or host), `protocol`,
  `device`, `limit` (default 50); empty fields are left out; returns `total`
  and `returned`.
- `list_sessions`, `open_connection`.
- `send_command` (`tab_id`, `command`, `intent`): by default waits for the
  prompt (`timeout_ms`, default 15000) and returns the command's own output,
  cleaned of escape codes and pager prompts, with `prompt`, `config_mode`,
  `timed_out` and `truncated`. Output longer than `max_chars` (default 8000)
  is cut by `keep`: `head`, `tail`, or `both` (default; half of each, with a
  note of how much was skipped). A cut answer has `total_chars`,
  `skipped_from` and `skipped_to`.
  Before the first command in a tab, MesTerm waits for the login and
  answers a "Press any key to continue" banner; paging is turned off once
  per tab on Aruba/HPE, Cisco, Palo Alto and Huawei, and pager prompts are
  answered. On a device that redraws the screen for each command
  (ArubaOS-Switch), the output starts below the command's last echo;
  `echo_found: false` says no echo was found. `wait: false` returns just the cursor, as
  before.
- `read_output`: with `offset` and `length`, part of the tab's last output
  (kept until its next command), so a skipped range is read without running
  the command again; otherwise an SSH tab's output since a cursor, cleaned
  and cut the same way.
- `read_screen`: any terminal's text, its prompt and whether that is a
  configuration prompt.

RDP tabs are listed but cannot be read.

When configuring the tunnel client, set `MCP_SERVER_URL` to the displayed URL
from a local secret store. Configure the tunnel ID and runtime key as described
in the [tunnel guide](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels).

## Development

```
flutter pub get
flutter run -d windows   # or -d macos
```

Windows builds use the OpenSSH client that ships with Windows 10/11
(Settings > Apps > Optional features > OpenSSH Client, on by default).
Where it is missing they fall back to PuTTY's `plink.exe`, which the
release installer bundles. macOS/Linux use the system `ssh`.

The macOS build ships **without App Sandbox**. An SSH client has to open
outbound connections and read the user's own `~/.ssh` (keys, `known_hosts`,
`config`, the agent socket); a sandboxed build gets a private container
instead and connects to nothing. Releases go out through GitHub, not the Mac
App Store, so the sandbox costs everything and buys nothing here. Upgrading
from 1.0.23 or earlier moves saved connections out of the old container
automatically, once, on first launch.

## Keyboard

| Keys | Does |
|---|---|
| Ctrl+Shift+P | Command palette: find and open a connection, or run a command |
| Ctrl+Shift+T | New connection |
| Ctrl+Tab, Ctrl+Shift+Tab | Next and previous tab |
| Ctrl+Shift+W | Close the tab |
| Ctrl+Shift+D | Split view |
| Ctrl+, | Settings |

Every other key, plain Ctrl ones included, goes to the session, as in PuTTY.

## Releases

Every push to `main` is a release. `.github/workflows/release.yml` runs the
analyzer and the tests, tags the next patch version (`v1.0.0`, `v1.0.1`,
`v1.0.2`...), builds Windows (installer + portable zip, `plink.exe` bundled)
and macOS (zipped .app) and publishes a GitHub Release. Installed apps find it
within five minutes and offer the update. A push that only changes Markdown
or `docs/` makes no release.

For a bigger step, push a tag by hand (`v1.1.0`, `v2.0.0`); the automatic
count carries on from it.

A `vX.Y.Z-beta.N` tag publishes a GitHub prerelease, without changing the
latest release. A beta is the same app at a newer version: it installs over
the normal one and keeps its connections, settings and password key. It is
taken by hand (its download, or Settings > Updates with Beta picked). The
automatic check offers normal releases only, so a beta install moves on to
the next normal release.

```
git tag v1.1.0
git push origin v1.1.0
```

## Third-party

PuTTY's `plink.exe` is bundled with the Windows installer/portable build,
under the MIT licence — see `third_party/PUTTY-LICENCE.txt`.
