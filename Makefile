.DEFAULT_GOAL := help

DC           = docker compose
RESULTS_DIR  = benchmarks/results
RUNNER       = $(DC) --profile runner run --rm --build radish-runner
JULIA_NATIVE = julia --project=.
THREADS      ?= 4

rebuild:            ## Force rebuild (no cache)
	$(DC) build --no-cache

# =============================================================================
#  Server
# =============================================================================

server:             ## Start server in Docker (background)
	$(DC) up -d --build radish-server

server-stop:        ## Stop Docker server
	$(DC) stop radish-server

server-logs:        ## Tail Docker server logs
	$(DC) logs -f radish-server

server-native:      ## Start server natively (no Docker, 8 threads)
	julia --threads=8 --project=. server_runner.jl

# =============================================================================
#  Client
# =============================================================================

client:             ## Attach interactive client (Docker, requires running server)
	$(DC) --profile client run --rm radish-client

client-native:      ## Start client natively (no Docker)
	$(JULIA_NATIVE) client_runner.jl

# =============================================================================
#  Simulator
# =============================================================================

SIM      = $(DC) --profile simulator run --rm --build radish-simulator julia --project=. workload_simulator.jl
SIM_HOST = --host radish-server --port 9000

simulator:          ## Run workload simulator (Docker, load + run)
	$(DC) --profile simulator run --rm --build radish-simulator

simload:            ## Load keys (Docker)
	$(SIM) load $(SIM_HOST)

simrun:             ## Run operations (Docker)
	$(SIM) run $(SIM_HOST)

simload-heavy:      ## Load 1M keys per type (Docker)
	$(SIM) load $(SIM_HOST) --num-keys 1000000

simrun-heavy:       ## Run 250k ops per client (Docker)
	$(SIM) run $(SIM_HOST) --num-ops 250000

# =============================================================================
#  Tests — Native (requires local Julia)
# =============================================================================

test:               ## Run unit tests (native)
	$(JULIA_NATIVE) test/runtests.jl

smoke-test:         ## Run smoke test (starts Docker server, tests over TCP, cleans up)
	python3 scripts/smoke_test.py

# =============================================================================
#  Tests — Docker (no local Julia needed)
# =============================================================================

docker-test:        ## Run unit tests inside Docker
	$(RUNNER) julia --project=. test/runtests.jl

docker-smoke-test:  ## Run smoke test inside Docker (server + test in containers)
	$(DC) up -d --build radish-server
	@echo "Waiting for server..."
	@for i in $$(seq 1 30); do \
		docker compose exec radish-server nc -z 127.0.0.1 9000 2>/dev/null && break; \
		[ $$i -eq 30 ] && echo "ERROR: Server not ready" && $(DC) stop radish-server && exit 1; \
		sleep 1; \
	done
	$(RUNNER) bash -c 'RADISH_HOST=radish-server python3 scripts/smoke_test.py --native'; \
	EXIT_CODE=$$?; \
	$(DC) stop radish-server; \
	exit $$EXIT_CODE

# =============================================================================
#  Benchmarks — Native (requires local Julia + Python3)
# =============================================================================

bench:              ## Internal benchmarks, Level 0/1 (native)
	@mkdir -p $(RESULTS_DIR)
	@BENCH_ID="$${BENCH_ID:-internals_$$(date +%Y%m%d_%H%M%S)}"; \
	OUTFILE="$(RESULTS_DIR)/$${BENCH_ID}.txt"; \
	echo "Running internal benchmarks → $$OUTFILE"; \
	BENCH_ID="$$BENCH_ID" $(JULIA_NATIVE) benchmarks/bench_internals.jl | tee "$$OUTFILE"

bench-system:       ## System benchmarks, Level 2 (native, $(THREADS) threads)
	@mkdir -p $(RESULTS_DIR)
	@BENCH_ID="$${BENCH_ID:-system_$$(date +%Y%m%d_%H%M%S)}"; \
	OUTFILE="$(RESULTS_DIR)/$${BENCH_ID}.txt"; \
	echo "Running system benchmarks → $$OUTFILE"; \
	BENCH_ID="$$BENCH_ID" julia --threads=$(THREADS) --project=. benchmarks/bench_system.jl | tee "$$OUTFILE"

bench-hotkey:       ## Hot-key contention benchmarks, 1→200k workers (native, $(THREADS) threads)
	@mkdir -p $(RESULTS_DIR)
	@BENCH_ID="$${BENCH_ID:-hotkey_$$(date +%Y%m%d_%H%M%S)}"; \
	OUTFILE="$(RESULTS_DIR)/$${BENCH_ID}.txt"; \
	echo "Running hot-key benchmarks → $$OUTFILE"; \
	BENCH_ID="$$BENCH_ID" julia --threads=$(THREADS) --project=. benchmarks/bench_system_hotkey.jl | tee "$$OUTFILE"

bench-read-scaling: ## Read scaling diagnostic, isolates scheduler/lock/store (native, $(THREADS) threads)
	@mkdir -p $(RESULTS_DIR)
	@BENCH_ID="$${BENCH_ID:-readscale_$$(date +%Y%m%d_%H%M%S)}"; \
	OUTFILE="$(RESULTS_DIR)/$${BENCH_ID}.txt"; \
	echo "Running read scaling diagnostic → $$OUTFILE"; \
	BENCH_ID="$$BENCH_ID" julia --threads=$(THREADS) --project=. benchmarks/bench_read_scaling.jl | tee "$$OUTFILE"

bench-all:          ## All benchmarks: Level 0-3 native, grouped in folder
	@TS=$$(date +%Y%m%d_%H%M%S); \
	RUN_DIR="$(RESULTS_DIR)/native_$$TS"; \
	mkdir -p "$$RUN_DIR"; \
	echo "══════════════════════════════════════════════════════"; \
	echo "  Radish Full Benchmark Suite (native)"; \
	echo "  Output: $$RUN_DIR/"; \
	echo "══════════════════════════════════════════════════════"; \
	echo ""; \
	echo "── 1/3 Internal Benchmarks (Level 0/1) ──────────────"; \
	BENCH_ID="internals" $(JULIA_NATIVE) benchmarks/bench_internals.jl \
		| tee "$$RUN_DIR/internals.txt"; \
	echo ""; \
	echo "── 2/3 System Benchmarks (Level 2) ──────────────────"; \
	BENCH_ID="system" julia --threads=$(THREADS) --project=. benchmarks/bench_system.jl \
		| tee "$$RUN_DIR/system.txt"; \
	echo ""; \
	echo "── 3/3 Network Benchmarks (Level 3, native) ──────────"; \
	julia --threads=8 --project=. server_runner.jl & \
	SERVER_PID=$$!; \
	echo "  Server PID: $$SERVER_PID"; \
	for i in $$(seq 1 30); do \
		nc -z 127.0.0.1 9000 2>/dev/null && echo "  Server ready after $${i}s" && break; \
		[ $$i -eq 30 ] && echo "  ERROR: Server failed to start" && kill $$SERVER_PID 2>/dev/null && exit 1; \
		sleep 1; \
	done; \
	python3 benchmarks/bench_net.py | tee "$$RUN_DIR/net.txt"; \
	echo "── Stopping server ────────────────────────────────────"; \
	kill $$SERVER_PID 2>/dev/null; wait $$SERVER_PID 2>/dev/null; \
	echo ""; \
	echo "══════════════════════════════════════════════════════"; \
	echo "  Results: $$RUN_DIR/"; \
	echo "══════════════════════════════════════════════════════"

# =============================================================================
#  Benchmarks — Docker (no local Julia needed)
# =============================================================================

docker-bench-all:       ## All benchmarks inside Docker, grouped in timestamped folder
	$(eval RUN_DIR := $(RESULTS_DIR)/docker_$(shell date +%Y%m%d_%H%M%S))
	@mkdir -p $(RUN_DIR)
	@echo "══════════════════════════════════════════════════════"
	@echo "  Radish Full Benchmark Suite (Docker)"
	@echo "  Output: $(RUN_DIR)/"
	@echo "══════════════════════════════════════════════════════"
	$(DC) build --quiet
	$(DC) up -d radish-server
	@echo "Waiting for server..."
	@for i in $$(seq 1 30); do \
		docker compose exec radish-server nc -z 127.0.0.1 9000 2>/dev/null && break; \
		[ $$i -eq 30 ] && echo "ERROR: Server not ready" && $(DC) stop radish-server && exit 1; \
		sleep 1; \
	done
	@echo ""
	@echo "── 1/3 Internal Benchmarks (Level 0/1) ──────────────"
	$(RUNNER) bash -c 'BENCH_ID="docker_internals" julia --project=. benchmarks/bench_internals.jl' | tee "$(RUN_DIR)/internals.txt"
	@echo ""
	@echo "── 2/3 System Benchmarks (Level 2) ──────────────────"
	$(RUNNER) bash -c 'BENCH_ID="docker_system" julia --threads=$(THREADS) --project=. benchmarks/bench_system.jl' | tee "$(RUN_DIR)/system.txt"
	@echo ""
	@echo "── 3/3 Network Benchmarks (Level 3) ─────────────────"
	$(RUNNER) bash -c 'RADISH_HOST=radish-server python3 benchmarks/bench_net.py' | tee "$(RUN_DIR)/net.txt"
	@echo ""
	$(DC) stop radish-server
	@echo "══════════════════════════════════════════════════════"
	@echo "  Results: $(RUN_DIR)/"
	@echo "══════════════════════════════════════════════════════"

bench-diff:         ## Compare two result folders: make bench-diff BEFORE=dir1 AFTER=dir2
	@if [ -z "$(BEFORE)" ] || [ -z "$(AFTER)" ]; then \
		echo "Usage: make bench-diff BEFORE=benchmarks/results/full_<ts1> AFTER=benchmarks/results/full_<ts2>"; \
		exit 1; \
	fi
	@echo "  Comparing: $(BEFORE) → $(AFTER)"
	@for f in $(BEFORE)/*.txt; do \
		NAME=$$(basename "$$f"); \
		if [ -f "$(AFTER)/$$NAME" ]; then \
			echo ""; \
			python3 scripts/bench_compare.py "$$f" "$(AFTER)/$$NAME" || true; \
		else \
			echo "  ⚠ $$NAME: no matching file in $(AFTER)"; \
		fi; \
	done

# =============================================================================
#  Docs
# =============================================================================

docs:               ## Start Jekyll docs server (http://localhost:4000)
	$(DC) --profile docs up radish-docs

docs-bg:            ## Start docs server in background
	$(DC) --profile docs up -d radish-docs

docs-stop:          ## Stop docs server
	$(DC) stop radish-docs

docs-logs:          ## Tail docs logs
	$(DC) logs -f radish-docs

# =============================================================================
#  Teardown & Utilities
# =============================================================================

down:               ## Stop and remove all containers
	$(DC) --profile client --profile docs --profile simulator --profile runner down

clean:              ## Remove containers, networks, and volumes (wipes data!)
	$(DC) --profile client --profile docs --profile simulator --profile runner down -v

ps:                 ## Show status of all Radish containers
	$(DC) ps -a

logs:               ## Tail logs for all running containers
	$(DC) logs -f

storage:            ## Show persistence file sizes (Docker server)
	@docker compose exec radish-server sh -c '\
		echo "AOF:"; \
		AOF=/app/persistence/aof/radish.aof; \
		if [ -f "$$AOF" ]; then \
			SIZE=$$(ls -lh $$AOF | awk "{print \$$5}"); \
			LINES=$$(wc -l < $$AOF); \
			echo "  $$AOF: $$SIZE ($$LINES lines)"; \
		else echo "  (no AOF file)"; fi; \
		echo "Snapshots:"; \
		SNAP=/app/persistence/snapshots; \
		if [ -d "$$SNAP" ]; then \
			COUNT=$$(ls -1 $$SNAP/*.rdb 2>/dev/null | wc -l); \
			SIZE=$$(du -sh $$SNAP 2>/dev/null | cut -f1); \
			echo "  $$COUNT shard files, $$SIZE total"; \
		else echo "  (none)"; fi' 2>/dev/null || echo "  Server not running. Start with: make server"

# =============================================================================
#  Help
# =============================================================================

help:
	@printf "\n"
	@printf "  \033[1mRadish Makefile\033[0m\n"
	@printf "  Native targets require local Julia + Python3.\n"
	@printf "  Docker targets (docker-*) run everything inside containers.\n"
	@printf "  Set THREADS=N to control thread count (default: 4).\n"
	@printf "\n"
	@printf "  \033[1m── Server ──────────────────────────────────────────────────────────\033[0m\n"
	@printf "  \033[36mserver\033[0m                 Start server in Docker (background)\n"
	@printf "  \033[36mserver-stop\033[0m            Stop Docker server\n"
	@printf "  \033[36mserver-logs\033[0m            Tail Docker server logs\n"
	@printf "  \033[36mserver-native\033[0m          Start server natively (8 threads)\n"
	@printf "\n"
	@printf "  \033[1m── Client ──────────────────────────────────────────────────────────\033[0m\n"
	@printf "  \033[36mclient\033[0m                 Attach interactive client (Docker)\n"
	@printf "  \033[36mclient-native\033[0m          Start client natively\n"
	@printf "\n"
	@printf "  \033[1m── Simulator ───────────────────────────────────────────────────────\033[0m\n"
	@printf "  \033[36msimulator\033[0m              Run workload simulator (Docker)\n"
	@printf "  \033[36msimload\033[0m / \033[36msimrun\033[0m         Load keys / run ops (Docker)\n"
	@printf "  \033[36msimload-heavy\033[0m / \033[36msimrun-heavy\033[0m  1M keys / 250k ops\n"
	@printf "\n"
	@printf "  \033[1m── Tests ───────────────────────────────────────────────────────────\033[0m\n"
	@printf "  \033[36mtest\033[0m                   Unit tests (native)\n"
	@printf "  \033[36msmoke-test\033[0m             Smoke test (native + Docker server)\n"
	@printf "  \033[36mdocker-test\033[0m            Unit tests (Docker)\n"
	@printf "  \033[36mdocker-smoke-test\033[0m      Smoke test (all Docker)\n"
	@printf "\n"
	@printf "  \033[1m── Benchmarks ──────────────────────────────────────────────────────\033[0m\n"
	@printf "  \033[36mbench\033[0m                  Internal benchmarks Level 0/1 (native)\n"
	@printf "  \033[36mbench-system\033[0m           System benchmarks Level 2 (native)\n"
	@printf "  \033[36mbench-hotkey\033[0m           Hot-key contention 1→200k workers (native)\n"
	@printf "  \033[36mbench-read-scaling\033[0m     Read scaling diagnostic (native)\n"
	@printf "  \033[36mbench-all\033[0m              All benchmarks Level 0-3 (native, auto server)\n"
	@printf "                         \033[2m→ benchmarks/results/native_<timestamp>/\033[0m\n"
	@printf "  \033[36mdocker-bench-all\033[0m       All benchmarks Level 0-3 (Docker)\n"
	@printf "                         \033[2m→ benchmarks/results/docker_<timestamp>/\033[0m\n"
	@printf "  \033[36mbench-diff\033[0m             Compare two result folders\n"
	@printf "                         \033[2m$ make bench-diff BEFORE=results/dir1 AFTER=results/dir2\033[0m\n"
	@printf "\n"
	@printf "  \033[1m── Docs ────────────────────────────────────────────────────────────\033[0m\n"
	@printf "  \033[36mdocs\033[0m                   Start Jekyll docs server (http://localhost:4000)\n"
	@printf "  \033[36mdocs-bg\033[0m                Start docs server in background\n"
	@printf "  \033[36mdocs-stop\033[0m              Stop docs server\n"
	@printf "\n"
	@printf "  \033[1m── Teardown & Utilities ────────────────────────────────────────────\033[0m\n"
	@printf "  \033[36mrebuild\033[0m                Force rebuild (no cache)\n"
	@printf "  \033[36mdown\033[0m                   Stop and remove all containers\n"
	@printf "  \033[36mclean\033[0m                  Remove containers, networks, volumes (wipes data!)\n"
	@printf "  \033[36mps\033[0m                     Show container status\n"
	@printf "  \033[36mlogs\033[0m                   Tail all container logs\n"
	@printf "  \033[36mstorage\033[0m                Show persistence file sizes\n"
	@printf "\n"
	@printf "  \033[1m── Typical Workflows ───────────────────────────────────────────────\033[0m\n"
	@printf "  \033[2mAll in Docker (no local Julia):\033[0m\n"
	@printf "    $$ make docker-test && make docker-bench-all\n"
	@printf "  \033[2mBenchmark before/after a change:\033[0m\n"
	@printf "    $$ make docker-bench-all   # before\n"
	@printf "    $$ make rebuild && make docker-bench-all   # after\n"
	@printf "    $$ make bench-diff BEFORE=benchmarks/results/docker_<ts1> AFTER=benchmarks/results/docker_<ts2>\n"
	@printf "\n"

.PHONY: rebuild \
        server server-stop server-logs server-native \
        client client-native \
        simulator simload simrun simload-heavy simrun-heavy \
        test smoke-test docker-test docker-smoke-test \
        bench bench-system bench-hotkey bench-read-scaling bench-all \
        docker-bench-all \
        bench-diff \
        docs docs-bg docs-stop docs-logs \
        down clean ps logs storage help
