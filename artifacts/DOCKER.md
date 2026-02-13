# Running Radish with Docker

This guide covers how to run the Radish server and connect clients using Docker, without installing Julia or any dependencies on your machine.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) installed
- [Docker Compose](https://docs.docker.com/compose/install/) (included with Docker Desktop)

## 1. Build the image

From the project root:

```bash
docker compose build
```

This builds a single `radish` image used by both the server and client.

## 2. Start the server

```bash
docker compose up
```

You should see output like:

```
radish-server  | Initializing Radish Server...
radish-server  | Radish server listening on 0.0.0.0:9000
```

Add `-d` to run it in the background:

```bash
docker compose up -d
```

## 3. Connect a client

In a separate terminal:

```bash
docker compose run --rm radish-client
```

You'll get an interactive prompt:

```
🌱 Connecting to Radish server at radish-server:9000...
✅ Welcome to Radish Server
Type 'HELP' for commands or 'QUIT' to disconnect

RADISH-CLI>
```

Type `HELP` for the full list of commands.

## 4. Connect multiple clients

Each `docker compose run` spawns an independent client session. Open as many terminals as you need:

```bash
# Terminal 2
docker compose run --rm radish-client

# Terminal 3
docker compose run --rm radish-client
```

All clients share the same server and database.

## 5. Stop the server

If running in the foreground, press `Ctrl+C`.

If running in the background:

```bash
docker compose down
```

## Data persistence

Server data is stored in a Docker named volume (`radish-data`). This means:

- Data survives container restarts (`docker compose down` / `docker compose up`)
- Data is completely isolated from any local Radish instance you run outside Docker
- To wipe the database and start fresh:

```bash
docker compose down -v
```

## Connecting from the host

The server port is exposed on `localhost:9000`, so you can also connect a local client (if you have Julia installed) or any TCP tool:

```bash
julia client_runner.jl 127.0.0.1 9000
```

## Useful commands

| Action | Command |
|---|---|
| Build the image | `docker compose build` |
| Start server | `docker compose up` |
| Start server (background) | `docker compose up -d` |
| Connect a client | `docker compose run --rm radish-client` |
| View server logs | `docker compose logs -f radish-server` |
| Stop everything | `docker compose down` |
| Stop and wipe data | `docker compose down -v` |
| Rebuild after code changes | `docker compose build --no-cache` |
