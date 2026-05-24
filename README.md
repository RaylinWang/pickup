# Pickup

Pickup is a macOS menu bar app for grouping AI work sessions and project links.

It can collect recent sessions from ChatGPT, Claude Code, Codex, and terminal-based workflows, then let you assign them to lightweight projects. You can also add manual links, such as Feishu docs or reference pages, to a project.

## Features

- Menu bar UI for project/session organization
- ChatGPT desktop, browser history, and sidebar title sync
- Claude Code and Codex session scanning
- Manual project links with custom names
- Hide noisy sessions without deleting synced data
- Open supported sessions or links from Pickup

## Local Data

Pickup stores data locally in `~/.sessiontracker/data.db`.

## Build

```bash
cd macapp
./build.sh
```

The packaged app is written to `macapp/build/Pickup.app`.
