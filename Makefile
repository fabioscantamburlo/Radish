.DEFAULT_GOAL := help

DC = docker compose

# ─── Build ────────────────────────────────────────────────────────────────────

build:          ## Build (or rebuild) the radish Docker image
	$(DC) build

rebuild:        ## Force rebuild the image from scratch (no cache)
	$(DC) build --no-cache

# ─── Server ───────────────────────────────────────────────────────────────────

server:         ## Start the server in the background
	$(DC) up -d radish-server

server-logs:    ## Tail the server logs (Ctrl+C to stop)
	$(DC) logs -f radish-server

server-stop:    ## Stop the server
	$(DC) stop radish-server

# ─── Client ───────────────────────────────────────────────────────────────────

client:         ## Attach an interactive client to the running server
	$(DC) --profile client run --rm radish-client

# ─── Simulator ────────────────────────────────────────────────────────────────

simulator:      ## Run the workload simulator (load + run) against the server
	$(DC) --profile simulator run --rm radish-simulator

simload:        ## Run simulator in load-only mode
	$(DC) --profile simulator run --rm radish-simulator julia --project=. workload_simulator.jl load --host radish-server --port 9000

simrun:         ## Run simulator in run-only mode
	$(DC) --profile simulator run --rm radish-simulator julia --project=. workload_simulator.jl run --host radish-server --port 9000

# ─── Docs ─────────────────────────────────────────────────────────────────────

docs-build:     ## Build the docs Docker image
	$(DC) --profile docs build radish-docs

docs:           ## Start the Jekyll docs server (http://localhost:4000)
	$(DC) --profile docs up radish-docs

docs-bg:        ## Start the docs server in the background
	$(DC) --profile docs up -d radish-docs

docs-logs:      ## Tail the docs logs (Ctrl+C to stop)
	$(DC) logs -f radish-docs

docs-stop:      ## Stop the docs server
	$(DC) stop radish-docs

# ─── Teardown ─────────────────────────────────────────────────────────────────

down:           ## Stop and remove all running containers
	$(DC) --profile client --profile docs --profile simulator down

clean:          ## Remove containers, networks and volumes (wipes persisted data!)
	$(DC) --profile client --profile docs --profile simulator down -v

# ─── Utilities ────────────────────────────────────────────────────────────────

ps:             ## Show status of all Radish containers
	$(DC) ps -a

logs:           ## Tail logs for all running containers (Ctrl+C to stop)
	$(DC) logs -f

help:           ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*##"}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: build rebuild server server-logs server-stop client \
        simulator simload simrun \
        docs-build docs docs-bg docs-logs docs-stop \
        down clean ps logs help
