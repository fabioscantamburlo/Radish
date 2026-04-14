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

smoke-test:     ## Run end-to-end smoke test (rebuild Docker, test every command)
	python3 scripts/smoke_test.py

bench-compare:  ## Compare two benchmark files (BEFORE=... AFTER=...)
	@python3 scripts/bench_compare.py $(BEFORE) $(AFTER)

bench:          ## Run internal benchmarks and save to benchmarks/<id>_<timestamp>.txt
	@mkdir -p benchmarks
	@BENCH_ID="$${BENCH_ID:-$$(date +%Y%m%d_%H%M%S)}"; \
	OUTFILE="benchmarks/$${BENCH_ID}.txt"; \
	echo "Running benchmarks → $$OUTFILE"; \
	BENCH_ID="$$BENCH_ID" julia --project=. test/bench_internals.jl | tee "$$OUTFILE"; \
	echo ""; \
	echo "Saved to $$OUTFILE"

test:           ## Run unit tests (strings, lists, hypercommands, meta commands)
	julia --project=. test/runtests.jl

test-all:       ## Run unit tests + smoke test
	@echo "── Unit Tests ──────────────────────────────────────"
	julia --project=. test/runtests.jl
	@echo ""
	@echo "── Smoke Test ──────────────────────────────────────"
	python3 scripts/smoke_test.py

bench-system:   ## Run system benchmarks (Level 2, 4 threads) and save to benchmarks/
	@mkdir -p benchmarks
	@BENCH_ID="$${BENCH_ID:-system_$$(date +%Y%m%d_%H%M%S)}"; \
	OUTFILE="benchmarks/$${BENCH_ID}.txt"; \
	echo "Running system benchmarks (4 threads) → $$OUTFILE"; \
	BENCH_ID="$$BENCH_ID" julia --threads=4 --project=. test/bench_system.jl | tee "$$OUTFILE"; \
	echo ""; \
	echo "Saved to $$OUTFILE"

bench-all:      ## Run all benchmarks (internal + system) and save to benchmarks/
	@mkdir -p benchmarks
	@TS="$$(date +%Y%m%d_%H%M%S)"; \
	echo "── Internal Benchmarks (Level 0/1) ──────────────────"; \
	BENCH_ID="all_internals_$$TS" julia --project=. test/bench_internals.jl | tee "benchmarks/all_internals_$$TS.txt"; \
	echo ""; \
	echo "── System Benchmarks (Level 2) ──────────────────────"; \
	BENCH_ID="all_system_$$TS" julia --threads=4 --project=. test/bench_system.jl | tee "benchmarks/all_system_$$TS.txt"; \
	echo ""; \
	echo "Saved to benchmarks/all_internals_$$TS.txt and benchmarks/all_system_$$TS.txt"

bench-net:      ## Run network benchmarks (Level 3, requires Docker)
	python3 scripts/bench_net.py

ps:             ## Show status of all Radish containers
	$(DC) ps -a

storage:        ## Show AOF and snapshot file sizes inside the server container
	@echo "── Persistence Storage ──────────────────────────────"
	@docker compose exec radish-server sh -c '\
		echo "AOF:"; \
		AOF=/app/persistence/aof/radish.aof; \
		if [ -f "$$AOF" ]; then \
			SIZE=$$(ls -lh $$AOF | awk "{print \$$5}"); \
			LINES=$$(wc -l < $$AOF); \
			echo "  $$AOF: $$SIZE ($$LINES lines)"; \
		else \
			echo "  (no AOF file)"; \
		fi; \
		echo ""; \
		echo "Snapshots:"; \
		SNAP_DIR=/app/persistence/snapshots; \
		if [ -d "$$SNAP_DIR" ]; then \
			COUNT=$$(ls -1 $$SNAP_DIR/*.rdb 2>/dev/null | wc -l); \
			SIZE=$$(du -sh $$SNAP_DIR 2>/dev/null | cut -f1); \
			echo "  $$COUNT shard files, $$SIZE total"; \
		else \
			echo "  (no snapshots directory)"; \
		fi' 2>/dev/null || echo "  Server container not running. Start with: make server"

storage-watch:  ## Live-refresh storage sizes every second (Ctrl+C to stop)
	@while true; do \
		printf "\033[2J\033[H"; \
		echo "── Persistence Storage (live) ── $$(date +%H:%M:%S) ──"; \
		echo ""; \
		docker compose exec -T radish-server sh -c '\
			AOF=/app/persistence/aof/radish.aof; \
			if [ -f "$$AOF" ]; then \
				SIZE=$$(ls -lh $$AOF | awk "{print \$$5}"); \
				LINES=$$(wc -l < $$AOF); \
				echo "  AOF: $$SIZE ($$LINES lines)"; \
			else \
				echo "  AOF: (no file)"; \
			fi; \
			SNAP_DIR=/app/persistence/snapshots; \
			if [ -d "$$SNAP_DIR" ]; then \
				COUNT=$$(ls -1 $$SNAP_DIR/*.rdb 2>/dev/null | wc -l); \
				SIZE=$$(du -sh $$SNAP_DIR 2>/dev/null | cut -f1); \
				echo "  Snapshots: $$COUNT shards, $$SIZE total"; \
			else \
				echo "  Snapshots: (none)"; \
			fi' 2>/dev/null || echo "  Server not running."; \
		sleep 1; \
	done

logs:           ## Tail logs for all running containers (Ctrl+C to stop)
	$(DC) logs -f

help:           ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*##"}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: build rebuild server server-logs server-stop client smoke-test bench-compare \
        simulator simload simrun \
        simload-light simload-heavy simload-vheavy \
        simrun-light simrun-heavy simrun-vheavy \
        docs-build docs docs-bg docs-logs docs-stop \
        down clean ps storage storage-watch logs help \
        test test-all bench bench-system bench-all bench-net
