.DEFAULT_GOAL := help

DC = docker compose
RESULTS_DIR = benchmarks/results

# ─── Build ────────────────────────────────────────────────────────────────────

build:          ## Build (or rebuild) the radish Docker image
	$(DC) build

rebuild:        ## Force rebuild the image from scratch (no cache)
	$(DC) build --no-cache

# ─── Server ───────────────────────────────────────────────────────────────────

server:         ## Start the Docker server in the background
	$(DC) up -d radish-server

server-logs:    ## Tail the Docker server logs (Ctrl+C to stop)
	$(DC) logs -f radish-server

server-stop:    ## Stop the Docker server
	$(DC) stop radish-server

server-native:  ## Start the server natively (no Docker, localhost:9000, 8 threads)
	julia --threads=8 --project=. server_runner.jl

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

simload-light:      ## Load 100k keys per type (10 clients)
	$(SIM) load $(SIM_HOST) --num-keys 100000

simload-heavy:      ## Load 1M keys per type (10 clients)
	$(SIM) load $(SIM_HOST) --num-keys 1000000

simload-vheavy:     ## Load 10M keys per type (10 clients)
	$(SIM) load $(SIM_HOST) --num-keys 10000000

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

# ─── Testing ──────────────────────────────────────────────────────────────────

test:           ## Run unit tests (strings, lists, hypercommands, meta commands)
	julia --project=. test/runtests.jl

smoke-test:     ## Run end-to-end smoke test (rebuild Docker, test every command)
	python3 scripts/smoke_test.py

test-all:       ## Run unit tests + smoke test
	@echo "── Unit Tests ──────────────────────────────────────"
	julia --project=. test/runtests.jl
	@echo ""
	@echo "── Smoke Test ──────────────────────────────────────"
	python3 scripts/smoke_test.py

validate:       ## Run all validation gates (unit tests + smoke test + internal bench + system bench)
	@echo "══════════════════════════════════════════════════════"
	@echo "  Radish Full Validation"
	@echo "══════════════════════════════════════════════════════"
	@echo ""
	@echo "── 1/4 Unit Tests ──────────────────────────────────"
	julia --project=. test/runtests.jl
	@echo ""
	@echo "── 2/4 Smoke Test (Docker) ─────────────────────────"
	python3 scripts/smoke_test.py
	@echo ""
	@echo "── 3/4 Internal Benchmarks (Level 0/1) ─────────────"
	@mkdir -p $(RESULTS_DIR)
	@BENCH_ID="validate_internals_$$(date +%Y%m%d_%H%M%S)" julia --project=. benchmarks/bench_internals.jl | tee "$(RESULTS_DIR)/validate_internals_$$(date +%Y%m%d_%H%M%S).txt"
	@echo ""
	@echo "── 4/4 System Benchmarks (Level 2) ─────────────────"
	@BENCH_ID="validate_system_$$(date +%Y%m%d_%H%M%S)" julia --threads=4 --project=. benchmarks/bench_system.jl | tee "$(RESULTS_DIR)/validate_system_$$(date +%Y%m%d_%H%M%S).txt"
	@echo ""
	@echo "══════════════════════════════════════════════════════"
	@echo "  All validation gates passed."
	@echo "══════════════════════════════════════════════════════"

# ─── Benchmarks ───────────────────────────────────────────────────────────────
#   Code:    benchmarks/*.jl, benchmarks/*.py  (version controlled)
#   Results: benchmarks/results/               (gitignored)

bench:          ## Run internal benchmarks (Level 0/1)
	@mkdir -p $(RESULTS_DIR)
	@BENCH_ID="$${BENCH_ID:-internals_$$(date +%Y%m%d_%H%M%S)}"; \
	OUTFILE="$(RESULTS_DIR)/$${BENCH_ID}.txt"; \
	echo "Running internal benchmarks → $$OUTFILE"; \
	BENCH_ID="$$BENCH_ID" julia --project=. benchmarks/bench_internals.jl | tee "$$OUTFILE"; \
	echo "Saved to $$OUTFILE"

bench-system:   ## Run system benchmarks (Level 2, 4 threads)
	@mkdir -p $(RESULTS_DIR)
	@BENCH_ID="$${BENCH_ID:-system_$$(date +%Y%m%d_%H%M%S)}"; \
	OUTFILE="$(RESULTS_DIR)/$${BENCH_ID}.txt"; \
	echo "Running system benchmarks → $$OUTFILE"; \
	BENCH_ID="$$BENCH_ID" julia --threads=4 --project=. benchmarks/bench_system.jl | tee "$$OUTFILE"; \
	echo "Saved to $$OUTFILE"

bench-net:      ## Run network benchmarks over Docker (Level 3)
	@mkdir -p $(RESULTS_DIR)
	@OUTFILE="$(RESULTS_DIR)/net_docker_$$(date +%Y%m%d_%H%M%S).txt"; \
	echo "Running Docker network benchmarks → $$OUTFILE"; \
	python3 benchmarks/bench_net.py | tee "$$OUTFILE"; \
	echo "Saved to $$OUTFILE"

bench-native:   ## Run network benchmarks against native server (start server-native first)
	@mkdir -p $(RESULTS_DIR)
	@OUTFILE="$(RESULTS_DIR)/net_native_$$(date +%Y%m%d_%H%M%S).txt"; \
	echo "Running native network benchmarks → $$OUTFILE"; \
	python3 benchmarks/bench_net.py --native | tee "$$OUTFILE"; \
	echo "Saved to $$OUTFILE"

bench-local:    ## Run local benchmarks (internal + system, no Docker needed)
	@mkdir -p $(RESULTS_DIR)
	@TS="$$(date +%Y%m%d_%H%M%S)"; \
	echo "── Internal Benchmarks (Level 0/1) ──────────────────"; \
	BENCH_ID="local_internals_$$TS" julia --project=. benchmarks/bench_internals.jl | tee "$(RESULTS_DIR)/local_internals_$$TS.txt"; \
	echo ""; \
	echo "── System Benchmarks (Level 2) ──────────────────────"; \
	BENCH_ID="local_system_$$TS" julia --threads=4 --project=. benchmarks/bench_system.jl | tee "$(RESULTS_DIR)/local_system_$$TS.txt"; \
	echo "Saved to $(RESULTS_DIR)/local_*_$$TS.txt"

bench-all:      ## Run ALL benchmarks (internal + system + network/Docker)
	@mkdir -p $(RESULTS_DIR)
	@TS="$$(date +%Y%m%d_%H%M%S)"; \
	echo "── Internal Benchmarks (Level 0/1) ──────────────────"; \
	BENCH_ID="all_internals_$$TS" julia --project=. benchmarks/bench_internals.jl | tee "$(RESULTS_DIR)/all_internals_$$TS.txt"; \
	echo ""; \
	echo "── System Benchmarks (Level 2) ──────────────────────"; \
	BENCH_ID="all_system_$$TS" julia --threads=4 --project=. benchmarks/bench_system.jl | tee "$(RESULTS_DIR)/all_system_$$TS.txt"; \
	echo ""; \
	echo "── Network Benchmarks (Level 3) ─────────────────────"; \
	python3 benchmarks/bench_net.py | tee "$(RESULTS_DIR)/all_net_$$TS.txt"; \
	echo "Saved to $(RESULTS_DIR)/all_*_$$TS.txt"

bench-compare:  ## Compare two benchmark result files (BEFORE=... AFTER=...)
	@python3 scripts/bench_compare.py $(BEFORE) $(AFTER)

bench-diff:     ## Compare two full benchmark folders (BEFORE=dir AFTER=dir)
	@if [ -z "$(BEFORE)" ] || [ -z "$(AFTER)" ]; then \
		echo "Usage: make bench-diff BEFORE=benchmarks/results/full_<ts1> AFTER=benchmarks/results/full_<ts2>"; \
		exit 1; \
	fi
	@echo "══════════════════════════════════════════════════════════════════════════"
	@echo "  Comparing: $(BEFORE) → $(AFTER)"
	@echo "══════════════════════════════════════════════════════════════════════════"
	@FAIL=0; \
	for f in $(BEFORE)/*.txt; do \
		NAME=$$(basename "$$f"); \
		if [ -f "$(AFTER)/$$NAME" ]; then \
			echo ""; \
			python3 scripts/bench_compare.py "$$f" "$(AFTER)/$$NAME" || FAIL=1; \
		else \
			echo ""; \
			echo "  ⚠ $$NAME: no matching file in $(AFTER)"; \
		fi; \
	done; \
	for f in $(AFTER)/*.txt; do \
		NAME=$$(basename "$$f"); \
		if [ ! -f "$(BEFORE)/$$NAME" ]; then \
			echo ""; \
			echo "  ⚠ $$NAME: new in $(AFTER) (no baseline)"; \
		fi; \
	done

bench-full:     ## Run ALL benchmarks natively (no Docker): tests + Level 0-3 with auto server lifecycle
	@echo "══════════════════════════════════════════════════════════════════════════"
	@echo "  Radish Full Benchmark Suite (native, no Docker)"
	@echo "  $$(date)"
	@echo "══════════════════════════════════════════════════════════════════════════"
	@TS=$$(date +%Y%m%d_%H%M%S); \
	RUN_DIR="$(RESULTS_DIR)/full_$$TS"; \
	mkdir -p "$$RUN_DIR"; \
	echo "  Output: $$RUN_DIR/"; \
	echo ""; \
	echo "── 1/5 Unit Tests ────────────────────────────────────────────────────────"; \
	julia --project=. test/runtests.jl; \
	echo ""; \
	echo "── 2/5 Internal Benchmarks (Level 0/1) ──────────────────────────────────"; \
	BENCH_ID="full_internals_$$TS" julia --project=. benchmarks/bench_internals.jl \
		| tee "$$RUN_DIR/internals.txt"; \
	echo ""; \
	echo "── 3/5 System Benchmarks (Level 2, 4 threads) ───────────────────────────"; \
	BENCH_ID="full_system_$$TS" julia --threads=4 --project=. benchmarks/bench_system.jl \
		| tee "$$RUN_DIR/system.txt"; \
	echo ""; \
	echo "── 4/5 Starting native server (8 threads) ───────────────────────────────"; \
	julia --threads=8 --project=. server_runner.jl &  \
	SERVER_PID=$$!; \
	echo "  Server PID: $$SERVER_PID"; \
	echo "  Waiting for server to be ready..."; \
	for i in $$(seq 1 30); do \
		if nc -z 127.0.0.1 9000 2>/dev/null; then \
			echo "  Server ready after $${i}s"; \
			break; \
		fi; \
		if [ $$i -eq 30 ]; then \
			echo "  ERROR: Server failed to start after 30s"; \
			kill $$SERVER_PID 2>/dev/null; \
			exit 1; \
		fi; \
		sleep 1; \
	done; \
	echo ""; \
	echo "── 5/5 Network Benchmarks (Level 3, native) ─────────────────────────────"; \
	python3 benchmarks/bench_net.py --native \
		| tee "$$RUN_DIR/net_native.txt"; \
	echo ""; \
	echo "── Stopping server ───────────────────────────────────────────────────────"; \
	kill $$SERVER_PID 2>/dev/null; \
	wait $$SERVER_PID 2>/dev/null; \
	echo "  Server stopped."; \
	echo ""; \
	echo "══════════════════════════════════════════════════════════════════════════"; \
	echo "  All benchmarks complete."; \
	echo "  Results: $$RUN_DIR/"; \
	echo "══════════════════════════════════════════════════════════════════════════"

# ─── Utilities ────────────────────────────────────────────────────────────────

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

.PHONY: build rebuild server server-logs server-stop server-native client \
        simulator simload simrun \
        simload-light simload-heavy simload-vheavy \
        simrun-light simrun-heavy simrun-vheavy \
        docs-build docs docs-bg docs-logs docs-stop \
        down clean \
        test smoke-test test-all validate \
        bench bench-system bench-net bench-native bench-local bench-all bench-full bench-compare bench-diff \
        ps storage storage-watch logs help
