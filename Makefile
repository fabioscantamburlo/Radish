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

SIM = $(DC) --profile simulator run --rm radish-simulator julia --project=. workload_simulator.jl
SIM_HOST = --host radish-server --port 9000

simulator:          ## Run the workload simulator (load + run, default settings)
	$(DC) --profile simulator run --rm radish-simulator

simload:            ## Load keys (default: 5k keys, 10 clients)
	$(SIM) load $(SIM_HOST)

simrun:             ## Run operations (default: 10k ops, 10 clients)
	$(SIM) run $(SIM_HOST)

# Tiered load targets — keys per type, 10 clients
simload-light:      ## Load 100k keys per type (10 clients)
	$(SIM) load $(SIM_HOST) --num-keys 100000

simload-heavy:      ## Load 1M keys per type (10 clients)
	$(SIM) load $(SIM_HOST) --num-keys 1000000

simload-vheavy:     ## Load 10M keys per type (10 clients)
	$(SIM) load $(SIM_HOST) --num-keys 10000000

# Tiered run targets — ops per client, 10 clients
simrun-light:       ## Run 100k ops per client (10 clients)
	$(SIM) run $(SIM_HOST) --num-ops 100000

simrun-heavy:       ## Run 250k ops per client (10 clients)
	$(SIM) run $(SIM_HOST) --num-ops 250000

simrun-vheavy:      ## Run 1M ops per client (10 clients)
	$(SIM) run $(SIM_HOST) --num-ops 1000000

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
        simload-light simload-heavy simload-vheavy \
        simrun-light simrun-heavy simrun-vheavy \
        docs-build docs docs-bg docs-logs docs-stop \
        down clean ps logs help
