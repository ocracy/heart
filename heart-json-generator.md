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

| field    | type     | when to set                                                  |
|----------|----------|--------------------------------------------------------------|
| `id`     | string   | always — short unique slug (`api`, `web`, `worker-queue`)    |
| `name`   | string   | always — sidebar label, capitalized                          |
| `command`| string   | always — what to run (will execute under `zsh -l -i -c`)     |
| `cwd`    | string   | always — absolute path or `~/...`                            |
| `port`   | int      | when the service binds a TCP port (HTTP, WS, redis, postgres)|
| `url`    | string   | when the service has an HTTP UI worth previewing             |
| `folder` | string   | sidebar nesting; slash-separated: `Backend/Workers`          |
| `kind`   | "claude" | only for Claude Code shortcut tasks                          |

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

### Claude Code shortcuts

For an "agent fan-out" experience, append shortcuts:
- One at the project **root** → `Claude (root)`.
- One per top-level service directory you registered (`api`, `web`, `mobile`, …) → `Claude (api)`, `Claude (web)`, etc.

Each shortcut:
```json
{
  "id": "claude-<slug>",
  "name": "Claude (<slug>)",
  "command": "claude",
  "cwd": "<absolute path>",
  "kind": "claude"
}
```

Place them under the same `folder` as the corresponding service when you used folders, otherwise leave folderless.

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

## Output formatting

- Two-space indentation, one task per object.
- Order: frontends together, backends together, supporting daemons next, Claude shortcuts last.
- After writing the file, print a short summary of what was found (which services, which were skipped and why) and remind the user: *"Drag `heart.json` into Heart's sidebar to import — every task lands under the project folder."*

## Worked example

For a project at `~/projects/my-shop`:

```
my-shop/
├── api/                    Laravel
│   ├── composer.json
│   └── artisan
├── web/                    Vite + React
│   └── package.json
└── admin/                  Next.js
    └── package.json
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
      "port": 8000,
      "url": "http://localhost:8000"
    },
    {
      "id": "web",
      "name": "Web",
      "command": "npm run dev",
      "cwd": "~/projects/my-shop/web",
      "folder": "Frontend",
      "port": 5173,
      "url": "http://localhost:5173"
    },
    {
      "id": "admin",
      "name": "Admin",
      "command": "npm run dev",
      "cwd": "~/projects/my-shop/admin",
      "folder": "Frontend",
      "port": 3000,
      "url": "http://localhost:3000"
    },
    {
      "id": "claude-root",
      "name": "Claude (root)",
      "command": "claude",
      "cwd": "~/projects/my-shop",
      "kind": "claude"
    },
    {
      "id": "claude-api",
      "name": "Claude (api)",
      "command": "claude",
      "cwd": "~/projects/my-shop/api",
      "folder": "Backend",
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

## Installing this skill (for users who want to reuse it across projects)

Save this file as `~/.claude/skills/heart-json-generator/SKILL.md` and Claude will auto-discover it. Then in any project: ask Claude to *"generate a Heart bundle for this project using the heart-json-generator skill"*.

Or copy this single file into your project's repo (e.g. `.claude/skills/heart-json-generator/SKILL.md`) so it ships with the codebase.
