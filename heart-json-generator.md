---
name: heart-json-generator
description: Scan the current project for dev services (frontend dev servers, backend HTTP servers, queue workers, supporting daemons) and emit a `heart.json` bundle at the project root, plus Claude shortcuts for each package directory. Heart (https://github.com/ocracy/heart) is a single-window macOS launcher that imports this bundle as a folder and starts every service from one place.
---

# Heart JSON generator

Walk the current project tree and emit a `heart.json` Heart can drag-drop import. Heart spawns every dev service in one window — terminal + in-app browser preview + Claude Code shortcuts side by side — so the goal of this skill is to discover **everything** that needs to run for local development and wire it up correctly.

## What to produce

Write **one file** at the project root: `heart.json`. Use the bundle shape:

```json
{
  "name": "<project name>",
  "tasks": [ /* Task[] */ ]
}
```

## Task shape

| field    | type                | when to set                                                                          |
|----------|---------------------|--------------------------------------------------------------------------------------|
| `id`     | string              | always — short unique slug (`api`, `web`, `worker-queue`)                            |
| `name`   | string              | always — sidebar label, capitalized                                                  |
| `command`| string              | always — what to run (will execute under `zsh -l -i -c`)                             |
| `cwd`    | string              | always — absolute path or `~/...`                                                    |
| `port`   | int                 | when the service binds a TCP port (HTTP, WS, redis, postgres)                        |
| `url`    | string              | when the service has an HTTP UI worth previewing                                     |
| `folder` | string              | sidebar nesting; slash-separated: `Backend/Workers`                                  |
| `icon`   | string              | optional SF Symbol name (e.g. `bolt.fill`, `database`, `globe`) shown next to `name` |
| `kind`   | "claude" \| "quick" | special task types — see below                                                       |

### Task kinds

There are three kinds of tasks Heart understands. Choose the right one — the
UI surfaces each differently.

| `kind`     | What it is                                              | Lives in the sidebar as…                                       |
|------------|---------------------------------------------------------|----------------------------------------------------------------|
| *(unset)*  | Long-running service. Manual start/stop, status dot.    | Regular row with play/stop/restart buttons + port + URL chips. |
| `"claude"` | Claude Code shortcut. Multi-session, fresh terminal.    | Sparkles row pinned at the top of the sidebar.                 |
| `"quick"`  | One-shot command (build, clean, migrate, etc.).         | Compact chip above the sidebar — one click runs, one click stops, output appears in the detail pane. |

**Quick actions** are the place to put commands a developer runs **on demand**
— not all the time. They have no port, no URL, no auto-readiness check; the
command fires, its output streams into the terminal, and the user can stop
it or just walk away. Pick 1–3 per project that the user reaches for most
often (formatters, cache busters, migrations, codegen, install, …).

## Picking icons

`icon` is an SF Symbol name. Heart renders it next to the task `name` in the
sidebar / chip / Claude row. The right icon makes a 12-task project
scannable in one glance — wrong icons (or missing ones) make every row look
the same. Pick one per task.

### Rules

1. **Use only real SF Symbols.** Heart targets macOS 13+ (SF Symbols 4 baseline). If you're unsure a name is valid, fall back to a safer one from the list below — Heart silently renders nothing when the name is invalid, which is worse than a generic but real icon.
2. **Lowercase, dotted naming.** SF Symbol names are dot-separated, all lowercase: `arrow.triangle.2.circlepath`, `tray.full.fill`, `chart.line.uptrend.xyaxis`. No camelCase, no underscores, no spaces.
3. **Prefer `.fill` variants for chips and busy sidebars** — they read better at small sizes (`folder.fill` > `folder`, `bolt.fill` > `bolt`).
4. **Match the task's job, not its tech stack.** A queue worker is `tray.full.fill` regardless of whether it's Sidekiq / Horizon / Celery. A formatter is `paintbrush.fill` regardless of language.
5. **Quick actions get expressive icons.** Chip space is tight; the icon does the heavy lifting. Migrations → `arrow.triangle.2.circlepath`, cache busts → `trash`, builds → `hammer.fill`.
6. **Never invent icon names.** If you can't find a clean match in the table below, omit `icon` — the row will fall back to its kind's default style (status dot / sparkles).

### Recommended icons by task

| Task                            | Icon                              |
|---------------------------------|-----------------------------------|
| Web frontend (Vite/Next/Astro)  | `globe` or `safari.fill`          |
| Admin / dashboard frontend      | `chart.bar.fill`                  |
| HTTP API / backend server       | `server.rack`                     |
| GraphQL server                  | `point.3.connected.trianglepath.dotted` |
| Websocket / realtime server     | `antenna.radiowaves.left.and.right` |
| Queue worker (Horizon, Sidekiq, Celery) | `tray.full.fill`          |
| Cron / scheduler                | `clock.fill`                      |
| Database (Postgres, MySQL)      | `cylinder.split.1x2`              |
| Redis / cache server            | `bolt.horizontal.circle.fill`     |
| Message broker (RabbitMQ, Kafka)| `arrow.triangle.swap`             |
| Object storage emulator (Minio) | `externaldrive.fill`              |
| Mail catcher (Mailpit, MailHog) | `envelope.fill`                   |
| Search index (Meilisearch, ES)  | `magnifyingglass`                 |
| Docker compose                  | `shippingbox.fill`                |
| ngrok / tunnel                  | `network`                         |
| Mobile dev server (Expo, Metro) | `iphone`                          |
| Claude Code shortcut            | `sparkles` (default, can omit)    |

### Recommended icons by quick action

| Quick action                | Icon                                |
|-----------------------------|-------------------------------------|
| Install / npm install       | `shippingbox.fill`                  |
| Build / compile             | `hammer.fill`                       |
| Migrate / schema sync       | `arrow.triangle.2.circlepath`       |
| Seed database               | `leaf.fill`                         |
| Cache clear / optimize:clear| `trash`                             |
| Optimize / warm caches      | `bolt.fill`                         |
| Format / prettier           | `paintbrush.fill`                   |
| Lint                        | `checkmark.seal.fill`               |
| Run tests                   | `checkmark.circle.fill`             |
| Typecheck                   | `chevron.left.forwardslash.chevron.right` |
| Generate types / codegen    | `curlybraces`                       |
| Collect static / assets     | `tray.and.arrow.down.fill`          |
| Docker down / stop          | `stop.fill`                         |
| Restart / reload            | `arrow.clockwise`                   |
| Open URL in browser         | `safari.fill`                       |
| Open repo in editor         | `chevron.left.forwardslash.chevron.right` |

## Detection rules

Walk the project at most **3 directory levels deep** unless the layout is clearly a monorepo (`pnpm-workspace.yaml`, `turbo.json`, `lerna.json`, `nx.json`, `apps/`, `packages/`, `services/`). For each detected service, register **one task**.

### Frontend (Node)

For each `package.json`:
- Read `scripts`. Pick the dev script in priority order: `dev` > `start` > `serve` > `develop`. Skip `build`, `test`, `lint`, `typecheck`.
- Resolve the bound port:
  - **Vite** → 5173 by default; check `vite.config.{js,ts,mjs}` for `server.port`.
  - **Next.js** → 3000 by default; respect `-p <port>` / `--port <port>` in the script.
  - **Webpack dev server** → check `webpack.config.{js,ts}` `devServer.port`.
  - **Astro** → 4321.
  - **Nuxt** → 3000.
  - Otherwise scan the script string for `--port`/`-p`, or look at `process.env.PORT` defaults in `server.{js,ts}` / `index.{js,ts}`.
- Set `url` to `http://localhost:<port>` if a port was found.
- Set `folder: "Frontend"` for these tasks.
- `name` ← `package.json#name` (capitalized, de-kebab'd) or the directory name.

### Backend

- **Laravel** (`composer.json` lists `laravel/framework`, or `artisan` file present):
  - Always: `php artisan serve` → port 8000, url `http://localhost:8000`, name `API`.
  - If `laravel/horizon` in composer.json → also `php artisan horizon`, name `Horizon`.
  - If `laravel/reverb` → also `php artisan reverb:start` with port (default 8080, override from `config/reverb.php`).
  - If queue config present and the user uses queues → optionally `php artisan queue:work`.
- **Django** (`manage.py` exists):
  - `python manage.py runserver` → port 8000.
  - If `celery` in `requirements.txt` / `pyproject.toml` → `celery -A <app> worker`.
- **Rails** (`Gemfile` mentions `rails`):
  - `bin/rails server` → port 3000.
  - If `sidekiq` in Gemfile → `bundle exec sidekiq`.
- **Express / Fastify / Hono / NestJS** (Node backend):
  - Use the package.json dev script; detect port from script flags or `app.listen(...)`.
- **Go**: `go run ./cmd/server` (or whatever the obvious entrypoint is).
- **Rust**: `cargo run` (`cargo watch -x run` if `cargo-watch` is in dev-dependencies).
- **Python (uvicorn / FastAPI / Starlette)**: `uvicorn app:app --reload` → port from `--port`.
- **Phoenix (Elixir)**: `mix phx.server` → port 4000.

### Supporting services

- **`docker-compose.yml`**: only register services the user clearly runs locally during development (databases, caches, message brokers). Translate to `docker compose up <service>`. Skip test fixtures and one-shot containers.
- **redis** / **postgres** with config files at the repo root (`redis.conf`, `postgresql.conf`) → register `redis-server` / `postgres -D ./pgdata`.
- **Mailpit / MailHog / Mailcatcher**: include if config references it.
- **ngrok**: if `ngrok` is configured (e.g. `ngrok.yml` or a known wrapper command), include it with `url: "http://localhost:4040"` (the inspector UI).

### Quick actions

For each detected stack, pick the 1–3 commands developers run most often by
hand — the ones that don't belong in a long-running terminal but are
annoying to retype. Emit them as `kind: "quick"`, no `port`, no `url`. Give
each a short `name` (1–2 words) so the chip stays compact; pick an SF
Symbol for `icon` so the chip is recognizable even when truncated.

Place each chip's `folder` under the matching service's folder (e.g.
Laravel quick actions land in `Backend`) so they sit alongside their
service in the sidebar tree.

Examples by stack:

**Laravel** (`composer.json` lists `laravel/framework`):
```json
{
  "id": "artisan-optimize",
  "name": "Optimize",
  "command": "php artisan optimize",
  "cwd": "<api-path>",
  "folder": "Backend",
  "icon": "bolt.fill",
  "kind": "quick"
},
{
  "id": "artisan-cache-clear",
  "name": "Cache clear",
  "command": "php artisan optimize:clear",
  "cwd": "<api-path>",
  "folder": "Backend",
  "icon": "trash",
  "kind": "quick"
},
{
  "id": "artisan-migrate",
  "name": "Migrate",
  "command": "php artisan migrate",
  "cwd": "<api-path>",
  "folder": "Backend",
  "icon": "arrow.triangle.2.circlepath",
  "kind": "quick"
}
```

**Node / npm** (any `package.json`):
```json
{
  "id": "npm-install",
  "name": "Install",
  "command": "npm install",
  "cwd": "<pkg-path>",
  "folder": "Frontend",
  "icon": "shippingbox.fill",
  "kind": "quick"
}
```

**Django** (`manage.py` exists):
```json
{
  "id": "django-migrate",
  "name": "Migrate",
  "command": "python manage.py migrate",
  "cwd": "<api-path>",
  "folder": "Backend",
  "icon": "arrow.triangle.2.circlepath",
  "kind": "quick"
},
{
  "id": "django-collectstatic",
  "name": "Collect static",
  "command": "python manage.py collectstatic --noinput",
  "cwd": "<api-path>",
  "folder": "Backend",
  "icon": "tray.and.arrow.down.fill",
  "kind": "quick"
}
```

**Rails** (`Gemfile` mentions `rails`):
```json
{
  "id": "rails-migrate",
  "name": "Migrate",
  "command": "bin/rails db:migrate",
  "cwd": "<api-path>",
  "folder": "Backend",
  "icon": "arrow.triangle.2.circlepath",
  "kind": "quick"
}
```

**Vite / Next.js / generic Node frontend**:
```json
{
  "id": "web-build",
  "name": "Build",
  "command": "npm run build",
  "cwd": "<web-path>",
  "folder": "Frontend",
  "icon": "hammer.fill",
  "kind": "quick"
}
```

**Docker compose** present:
```json
{
  "id": "docker-down",
  "name": "Down",
  "command": "docker compose down",
  "cwd": "<repo-root>",
  "icon": "stop.fill",
  "kind": "quick"
}
```

Keep the total quick-action count for a project small (≤ 5 across the
whole bundle). The chip bar scrolls horizontally but is meant to be a
short, scannable strip — anything beyond a handful belongs as a regular
task or stays a one-off shell command.

### Claude Code shortcuts

Only register a Claude shortcut for a directory that **already contains a
`CLAUDE.md`** file. `CLAUDE.md` is project-specific guidance that Claude
Code reads on launch, so its presence is the strongest signal that the
user actually runs `claude` from that directory.

Walk the project and, for every directory at any depth that contains a
`CLAUDE.md`, emit one Claude shortcut:

```json
{
  "id": "claude-<slug>",
  "name": "Claude (<slug>)",
  "command": "claude",
  "cwd": "<absolute path>",
  "kind": "claude"
}
```

Slug rules:
- Project root → `claude-root`, name `Claude (root)`.
- Sub-directory → `claude-<dir-slug>` (e.g. `apps/web/CLAUDE.md` → `claude-web`).

Place each shortcut under the same `folder` as the corresponding service
when you used folders, otherwise leave folderless.

**If no `CLAUDE.md` exists anywhere in the tree, do not emit any Claude
shortcuts.** Heart users can still spawn Claude sessions ad hoc; the goal
of this skill is to surface the ones the project explicitly opted into.

## Naming + IDs

- Bundle `name` = project root directory name, Title-Cased and de-kebab'd. `my-shop` → `My Shop`.
- Task `id`s: short, slug-like, unique within the bundle. `api`, `web-frontend`, `worker-queue`, `claude-api`.
- Task `name`s: clean human label. `API`, `Web`, `Queue worker`, `Claude (api)`.

## Don't

- Don't add tasks for build-only commands (`npm run build`, `npm test`, `npm run lint`).
- Don't add tasks for one-shots (migrations, seeders, codegen).
- Don't add CI / deploy scripts.
- Don't include secrets, tokens, or env values inline in `command`.
- Don't set `autoStart` (reserved, not yet implemented).
- Don't generate tasks for tooling Heart already provides (terminal, browser, etc).
- Don't invent SF Symbol names. Stick to names from the "Picking icons" tables above (they're verified against the SF Symbols 4 catalog Heart targets). If nothing fits, omit `icon` — wrong / nonexistent names render as a blank space, which looks worse than no icon.

## Output formatting

- Two-space indentation, one task per object.
- Order: long-running services first (frontends together, backends together, supporting daemons next), then quick-action chips, then Claude shortcuts last.
- After writing the file, print a short summary of what was found (which services, which were skipped and why) and remind the user: *"Drag `heart.json` into Heart's sidebar to import — every task lands under the project folder."*

## Worked example

For a project at `~/projects/my-shop`:

```
my-shop/
├── CLAUDE.md               ← root has Claude Code guidance
├── api/                    Laravel
│   ├── composer.json
│   └── artisan
├── web/                    Vite + React
│   ├── CLAUDE.md           ← web has component-specific guidance
│   └── package.json
└── admin/                  Next.js
    └── package.json        ← no CLAUDE.md → no Claude shortcut
```

Output `~/projects/my-shop/heart.json`:

```json
{
  "name": "My Shop",
  "tasks": [
    {
      "id": "api",
      "name": "API",
      "command": "php artisan serve",
      "cwd": "~/projects/my-shop/api",
      "folder": "Backend",
      "icon": "server.rack",
      "port": 8000,
      "url": "http://localhost:8000"
    },
    {
      "id": "web",
      "name": "Web",
      "command": "npm run dev",
      "cwd": "~/projects/my-shop/web",
      "folder": "Frontend",
      "icon": "globe",
      "port": 5173,
      "url": "http://localhost:5173"
    },
    {
      "id": "admin",
      "name": "Admin",
      "command": "npm run dev",
      "cwd": "~/projects/my-shop/admin",
      "folder": "Frontend",
      "icon": "chart.bar.fill",
      "port": 3000,
      "url": "http://localhost:3000"
    },
    {
      "id": "artisan-optimize",
      "name": "Optimize",
      "command": "php artisan optimize",
      "cwd": "~/projects/my-shop/api",
      "folder": "Backend",
      "icon": "bolt.fill",
      "kind": "quick"
    },
    {
      "id": "artisan-cache-clear",
      "name": "Cache clear",
      "command": "php artisan optimize:clear",
      "cwd": "~/projects/my-shop/api",
      "folder": "Backend",
      "icon": "trash",
      "kind": "quick"
    },
    {
      "id": "web-install",
      "name": "Install",
      "command": "npm install",
      "cwd": "~/projects/my-shop/web",
      "folder": "Frontend",
      "icon": "shippingbox.fill",
      "kind": "quick"
    },
    {
      "id": "claude-root",
      "name": "Claude (root)",
      "command": "claude",
      "cwd": "~/projects/my-shop",
      "kind": "claude"
    },
    {
      "id": "claude-web",
      "name": "Claude (web)",
      "command": "claude",
      "cwd": "~/projects/my-shop/web",
      "folder": "Frontend",
      "kind": "claude"
    }
  ]
}
```

Note: only `claude-root` and `claude-web` were emitted because those are
the only directories with `CLAUDE.md`. `api/` and `admin/` get no
shortcut even though they're real services.

## Installing this skill (for users who want to reuse it across projects)

Save this file as `~/.claude/skills/heart-json-generator/SKILL.md` and Claude will auto-discover it. Then in any project: ask Claude to *"generate a Heart bundle for this project using the heart-json-generator skill"*.

Or copy this single file into your project's repo (e.g. `.claude/skills/heart-json-generator/SKILL.md`) so it ships with the codebase.
