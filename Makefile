.DEFAULT_GOAL := help

DC           = docker compose
RESULTS_DIR  = benchmarks/results
RUNNER       = $(DC) --profile runner run --rm --build radish-runner
JULIA_NATIVE = julia --project=.
THREADS      ?= 4

# =============================================================================
#  Build
# =============================================================================

build:              ## Build the radish Docker image
	$(DC) build

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
	$(DC) --profile client run --rm --build radish-client

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

test-all:           ## Run unit tests + smoke test (native + Docker)
	@echo "── Unit Tests (native) ─────────────────────────────"
	$(JULIA_NATIVE) test/runtests.jl
	@echo ""
	@echo "── Smoke Test (Docker) ─────────────────────────────"
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

docker-test-all:    ## Run unit tests + smoke test inside Docker
	@echo "── Unit Tests (Docker) ─────────────────────────────"
	$(RUNNER) julia --project=. test/runtests.jl
	@echo ""
	@echo "── Smoke Test (Docker) ─────────────────────────────"
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

bench-net:          ## Network benchmarks, Level 3 over Docker TCP
	@mkdir -p $(RESULTS_DIR)
	@OUTFILE="$(RESULTS_DIR)/net_docker_$$(date +%Y%m%d_%H%M%S).txt"; \
	echo "Running Docker network benchmarks → $$OUTFILE"; \
	python3 benchmarks/bench_net.py | tee "$$OUTFILE"

bench-net-native:   ## Network benchmarks, Level 3 over native TCP (start server-native first)
	@mkdir -p $(RESULTS_DIR)
	@OUTFILE="$(RESULTS_DIR)/net_native_$$(date +%Y%m%d_%H%M%S).txt"; \
	echo "Running native network benchmarks → $$OUTFILE"; \
	python3 benchmarks/bench_net.py --native | tee "$$OUTFILE"

bench-all:          ## All benchmarks: Level 0-2 native + Level 3 Docker, grouped in folder
	@TS=$$(date +%Y%m%d_%H%M%S); \
	RUN_DIR="$(RESULTS_DIR)/native_$$TS"; \
	mkdir -p "$$RUN_DIR"; \
	echo "══════════════════════════════════════════════════════"; \
	echo "  Radish Full Benchmark Suite (native + Docker net)"; \
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
	echo "── 3/3 Network Benchmarks (Level 3, Docker) ─────────"; \
	python3 benchmarks/bench_net.py | tee "$$RUN_DIR/net.txt"; \
	echo ""; \
	echo "══════════════════════════════════════════════════════"; \
	echo "  Results: $$RUN_DIR/"; \
	echo "══════════════════════════════════════════════════════"

bench-full:         ## Full suite: tests + Level 0-3 with auto native server lifecycle
	@echo "══════════════════════════════════════════════════════════════════════════"
	@echo "  Radish Full Benchmark Suite (native)"
	@echo "══════════════════════════════════════════════════════════════════════════"
	@TS=$$(date +%Y%m%d_%H%M%S); \
	RUN_DIR="$(RESULTS_DIR)/full_$$TS"; \
	mkdir -p "$$RUN_DIR"; \
	echo "  Output: $$RUN_DIR/"; \
	echo ""; \
	echo "── 1/5 Unit Tests ────────────────────────────────────────────────────────"; \
	$(JULIA_NATIVE) test/runtests.jl; \
	echo ""; \
	echo "── 2/5 Internal Benchmarks (Level 0/1) ──────────────────────────────────"; \
	BENCH_ID="full_internals_$$TS" $(JULIA_NATIVE) benchmarks/bench_internals.jl \
		| tee "$$RUN_DIR/internals.txt"; \
	echo ""; \
	echo "── 3/5 System Benchmarks (Level 2) ───────────────────────────────────────"; \
	BENCH_ID="full_system_$$TS" julia --threads=$(THREADS) --project=. benchmarks/bench_system.jl \
		| tee "$$RUN_DIR/system.txt"; \
	echo ""; \
	echo "── 4/5 Starting native server (8 threads) ───────────────────────────────"; \
	julia --threads=8 --project=. server_runner.jl & \
	SERVER_PID=$$!; \
	echo "  Server PID: $$SERVER_PID"; \
	for i in $$(seq 1 30); do \
		nc -z 127.0.0.1 9000 2>/dev/null && echo "  Server ready after $${i}s" && break; \
		[ $$i -eq 30 ] && echo "  ERROR: Server failed to start" && kill $$SERVER_PID 2>/dev/null && exit 1; \
		sleep 1; \
	done; \
	echo ""; \
	echo "── 5/5 Network Benchmarks (Level 3, native) ─────────────────────────────"; \
	python3 benchmarks/bench_net.py --native | tee "$$RUN_DIR/net_native.txt"; \
	echo ""; \
	echo "── Stopping server ───────────────────────────────────────────────────────"; \
	kill $$SERVER_PID 2>/dev/null; wait $$SERVER_PID 2>/dev/null; \
	echo "  Results: $$RUN_DIR/"

# =============================================================================
#  Benchmarks — Docker (no local Julia needed)
# =============================================================================

docker-bench:           ## Internal benchmarks, Level 0/1 (Docker)
	@mkdir -p $(RESULTS_DIR)
	$(RUNNER) bash -c '\
		BENCH_ID="docker_internals_$$(date +%Y%m%d_%H%M%S)"; \
		BENCH_ID="$$BENCH_ID" julia --project=. benchmarks/bench_internals.jl \
		| tee benchmarks/results/$$BENCH_ID.txt'

docker-bench-system:    ## System benchmarks, Level 2 (Docker, $(THREADS) threads)
	@mkdir -p $(RESULTS_DIR)
	$(RUNNER) bash -c '\
		BENCH_ID="docker_system_$$(date +%Y%m%d_%H%M%S)"; \
		BENCH_ID="$$BENCH_ID" julia --threads=$(THREADS) --project=. benchmarks/bench_system.jl \
		| tee benchmarks/results/$$BENCH_ID.txt'

docker-bench-net:       ## Network benchmarks, Level 3 (all inside Docker)
	@mkdir -p $(RESULTS_DIR)
	$(DC) up -d --build radish-server
	@echo "Waiting for server..."
	@for i in $$(seq 1 30); do \
		docker compose exec radish-server nc -z 127.0.0.1 9000 2>/dev/null && break; \
		[ $$i -eq 30 ] && echo "ERROR: Server not ready" && $(DC) stop radish-server && exit 1; \
		sleep 1; \
	done
	$(RUNNER) bash -c 'RADISH_HOST=radish-server python3 benchmarks/bench_net.py --native' || true
	$(DC) stop radish-server

docker-bench-all:       ## All benchmarks inside Docker, grouped in timestamped folder
	@TS=$$(date +%Y%m%d_%H%M%S); \
	RUN_DIR="$(RESULTS_DIR)/docker_$$TS"; \
	mkdir -p "$$RUN_DIR"; \
	echo "══════════════════════════════════════════════════════"; \
	echo "  Radish Full Benchmark Suite (Docker)"; \
	echo "  Output: $$RUN_DIR/"; \
	echo "══════════════════════════════════════════════════════"; \
	echo ""; \
	echo "── 1/3 Internal Benchmarks (Level 0/1) ──────────────"; \
	$(RUNNER) bash -c '\
		BENCH_ID="docker_internals" \
		julia --project=. benchmarks/bench_internals.jl' \
		| tee "$$RUN_DIR/internals.txt"; \
	echo ""; \
	echo "── 2/3 System Benchmarks (Level 2) ──────────────────"; \
	$(RUNNER) bash -c '\
		BENCH_ID="docker_system" \
		julia --threads=$(THREADS) --project=. benchmarks/bench_system.jl' \
		| tee "$$RUN_DIR/system.txt"; \
	echo ""; \
	echo "── 3/3 Network Benchmarks (Level 3) ─────────────────"; \
	$(RUNNER) python3 benchmarks/bench_net.py \
		| tee "$$RUN_DIR/net.txt"; \
	echo ""; \
	echo "══════════════════════════════════════════════════════"; \
	echo "  Results: $$RUN_DIR/"; \
	echo "══════════════════════════════════════════════════════"

# =============================================================================
#  Benchmark Comparison
# =============================================================================

bench-compare:      ## Compare two result files: make bench-compare BEFORE=a.txt AFTER=b.txt
	@python3 scripts/bench_compare.py $(BEFORE) $(AFTER)

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
#  Validate (full gate: tests + benchmarks)
# =============================================================================

validate:           ## Full validation gate (native): unit tests + smoke test + benchmarks
	@echo "══════════════════════════════════════════════════════"
	@echo "  Radish Full Validation (native)"
	@echo "══════════════════════════════════════════════════════"
	@echo ""
	@echo "── 1/4 Unit Tests ──────────────────────────────────"
	$(JULIA_NATIVE) test/runtests.jl
	@echo ""
	@echo "── 2/4 Smoke Test (Docker) ─────────────────────────"
	python3 scripts/smoke_test.py
	@echo ""
	@echo "── 3/4 Internal Benchmarks ─────────────────────────"
	@mkdir -p $(RESULTS_DIR)
	$(JULIA_NATIVE) benchmarks/bench_internals.jl
	@echo ""
	@echo "── 4/4 System Benchmarks ───────────────────────────"
	julia --threads=$(THREADS) --project=. benchmarks/bench_system.jl
	@echo ""
	@echo "  All validation gates passed."

docker-validate:    ## Full validation gate (Docker): unit tests + smoke test + benchmarks
	@echo "══════════════════════════════════════════════════════"
	@echo "  Radish Full Validation (Docker)"
	@echo "══════════════════════════════════════════════════════"
	@echo ""
	@echo "── 1/4 Unit Tests ──────────────────────────────────"
	$(RUNNER) julia --project=. test/runtests.jl
	@echo ""
	@echo "── 2/4 Smoke Test ──────────────────────────────────"
	$(DC) up -d --build radish-server
	@for i in $$(seq 1 30); do \
		docker compose exec radish-server nc -z 127.0.0.1 9000 2>/dev/null && break; \
		[ $$i -eq 30 ] && echo "ERROR: Server not ready" && $(DC) stop radish-server && exit 1; \
		sleep 1; \
	done
	$(RUNNER) bash -c 'RADISH_HOST=radish-server python3 scripts/smoke_test.py --native'; \
	EXIT_CODE=$$?; \
	$(DC) stop radish-server; \
	[ $$EXIT_CODE -ne 0 ] && exit $$EXIT_CODE; true
	@echo ""
	@echo "── 3/4 Internal Benchmarks ─────────────────────────"
	$(RUNNER) julia --project=. benchmarks/bench_internals.jl
	@echo ""
	@echo "── 4/4 System Benchmarks ───────────────────────────"
	$(RUNNER) julia --threads=$(THREADS) --project=. benchmarks/bench_system.jl
	@echo ""
	@echo "  All validation gates passed."

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
	@printf "  \033[1m── Build ───────────────────────────────────────────────────────────\033[0m\n"
	@printf "  \033[36mbuild\033[0m                  Build the radish Docker image\n"
	@printf "                         \033[2m$$ make build\033[0m\n"
	@printf "  \033[36mrebuild\033[0m                Force rebuild (no cache)\n"
	@printf "                         \033[2m$$ make rebuild\033[0m\n"
	@printf "\n"
	@printf "  \033[1m── Server ──────────────────────────────────────────────────────────\033[0m\n"
	@printf "  \033[36mserver\033[0m                 Start server in Docker (background)\n"
	@printf "                         \033[2m$$ make server\033[0m\n"
	@printf "  \033[36mserver-stop\033[0m            Stop Docker server\n"
	@printf "                         \033[2m$$ make server-stop\033[0m\n"
	@printf "  \033[36mserver-logs\033[0m            Tail Docker server logs\n"
	@printf "                         \033[2m$$ make server-logs\033[0m\n"
	@printf "  \033[36mserver-native\033[0m          Start server natively (no Docker, 8 threads)\n"
	@printf "                         \033[2m$$ make server-native\033[0m\n"
	@printf "\n"
	@printf "  \033[1m── Client ──────────────────────────────────────────────────────────\033[0m\n"
	@printf "  \033[36mclient\033[0m                 Attach interactive client (Docker)\n"
	@printf "                         \033[2m$$ make server && make client\033[0m\n"
	@printf "  \033[36mclient-native\033[0m          Start client natively (no Docker)\n"
	@printf "                         \033[2m$$ make client-native\033[0m\n"
	@printf "\n"
	@printf "  \033[1m── Simulator ───────────────────────────────────────────────────────\033[0m\n"
	@printf "  \033[36msimulator\033[0m              Run workload simulator (Docker, load + run)\n"
	@printf "                         \033[2m$$ make server && make simulator\033[0m\n"
	@printf "  \033[36msimload\033[0m                Load keys into running server (Docker)\n"
	@printf "                         \033[2m$$ make simload\033[0m\n"
	@printf "  \033[36msimrun\033[0m                 Run operations against running server (Docker)\n"
	@printf "                         \033[2m$$ make simrun\033[0m\n"
	@printf "  \033[36msimload-heavy\033[0m          Load 1M keys per type (Docker)\n"
	@printf "                         \033[2m$$ make simload-heavy\033[0m\n"
	@printf "  \033[36msimrun-heavy\033[0m           Run 250k ops per client (Docker)\n"
	@printf "                         \033[2m$$ make simrun-heavy\033[0m\n"
	@printf "\n"
	@printf "  \033[1m── Tests (native) ─────────────────────────────────────────────────\033[0m\n"
	@printf "  \033[36mtest\033[0m                   Run unit tests\n"
	@printf "                         \033[2m$$ make test\033[0m\n"
	@printf "  \033[36msmoke-test\033[0m             End-to-end smoke test (spins up Docker server)\n"
	@printf "                         \033[2m$$ make smoke-test\033[0m\n"
	@printf "  \033[36mtest-all\033[0m               Unit tests + smoke test\n"
	@printf "                         \033[2m$$ make test-all\033[0m\n"
	@printf "\n"
	@printf "  \033[1m── Tests (Docker) ─────────────────────────────────────────────────\033[0m\n"
	@printf "  \033[36mdocker-test\033[0m            Run unit tests inside Docker\n"
	@printf "                         \033[2m$$ make docker-test\033[0m\n"
	@printf "  \033[36mdocker-smoke-test\033[0m      Smoke test inside Docker\n"
	@printf "                         \033[2m$$ make docker-smoke-test\033[0m\n"
	@printf "  \033[36mdocker-test-all\033[0m        Unit tests + smoke test inside Docker\n"
	@printf "                         \033[2m$$ make docker-test-all\033[0m\n"
	@printf "\n"
	@printf "  \033[1m── Benchmarks (native) ────────────────────────────────────────────\033[0m\n"
	@printf "  \033[36mbench\033[0m                  Internal benchmarks, Level 0/1\n"
	@printf "                         \033[2m$$ make bench\033[0m\n"
	@printf "  \033[36mbench-system\033[0m           System benchmarks, Level 2\n"
	@printf "                         \033[2m$$ make bench-system THREADS=8\033[0m\n"
	@printf "  \033[36mbench-net\033[0m              Network benchmarks, Level 3 (Docker TCP)\n"
	@printf "                         \033[2m$$ make bench-net\033[0m\n"
	@printf "  \033[36mbench-net-native\033[0m       Network benchmarks, Level 3 (native TCP)\n"
	@printf "                         \033[2m$$ make server-native  # terminal 1\033[0m\n"
	@printf "                         \033[2m$$ make bench-net-native  # terminal 2\033[0m\n"
	@printf "  \033[36mbench-all\033[0m              All benchmarks (Level 0-3), grouped in folder\n"
	@printf "                         \033[2m$$ make bench-all\033[0m\n"
	@printf "                         \033[2m→ benchmarks/results/native_<timestamp>/\033[0m\n"
	@printf "  \033[36mbench-full\033[0m             Tests + all benchmarks with auto server lifecycle\n"
	@printf "                         \033[2m$$ make bench-full\033[0m\n"
	@printf "                         \033[2m→ benchmarks/results/full_<timestamp>/\033[0m\n"
	@printf "\n"
	@printf "  \033[1m── Benchmarks (Docker) ────────────────────────────────────────────\033[0m\n"
	@printf "  \033[36mdocker-bench\033[0m           Internal benchmarks, Level 0/1\n"
	@printf "                         \033[2m$$ make docker-bench\033[0m\n"
	@printf "  \033[36mdocker-bench-system\033[0m    System benchmarks, Level 2\n"
	@printf "                         \033[2m$$ make docker-bench-system THREADS=8\033[0m\n"
	@printf "  \033[36mdocker-bench-net\033[0m       Network benchmarks, Level 3\n"
	@printf "                         \033[2m$$ make docker-bench-net\033[0m\n"
	@printf "  \033[36mdocker-bench-all\033[0m       All benchmarks (Level 0-3), grouped in folder\n"
	@printf "                         \033[2m$$ make docker-bench-all\033[0m\n"
	@printf "                         \033[2m→ benchmarks/results/docker_<timestamp>/\033[0m\n"
	@printf "\n"
	@printf "  \033[1m── Benchmark Comparison ────────────────────────────────────────────\033[0m\n"
	@printf "  \033[36mbench-compare\033[0m          Compare two result files side-by-side\n"
	@printf "                         \033[2m$$ make bench-compare BEFORE=results/old.txt AFTER=results/new.txt\033[0m\n"
	@printf "  \033[36mbench-diff\033[0m             Compare two result folders (matched by filename)\n"
	@printf "                         \033[2m$$ make bench-diff BEFORE=results/docker_20260417 AFTER=results/docker_20260418\033[0m\n"
	@printf "\n"
	@printf "  \033[1m── Validation ─────────────────────────────────────────────────────\033[0m\n"
	@printf "  \033[36mvalidate\033[0m               Full gate: tests + benchmarks (native)\n"
	@printf "                         \033[2m$$ make validate\033[0m\n"
	@printf "  \033[36mdocker-validate\033[0m        Full gate: tests + benchmarks (Docker)\n"
	@printf "                         \033[2m$$ make docker-validate\033[0m\n"
	@printf "\n"
	@printf "  \033[1m── Docs ────────────────────────────────────────────────────────────\033[0m\n"
	@printf "  \033[36mdocs\033[0m                   Start Jekyll docs server (http://localhost:4000)\n"
	@printf "                         \033[2m$$ make docs\033[0m\n"
	@printf "  \033[36mdocs-bg\033[0m                Start docs server in background\n"
	@printf "                         \033[2m$$ make docs-bg\033[0m\n"
	@printf "  \033[36mdocs-stop\033[0m              Stop docs server\n"
	@printf "                         \033[2m$$ make docs-stop\033[0m\n"
	@printf "  \033[36mdocs-logs\033[0m              Tail docs logs\n"
	@printf "                         \033[2m$$ make docs-logs\033[0m\n"
	@printf "\n"
	@printf "  \033[1m── Teardown & Utilities ────────────────────────────────────────────\033[0m\n"
	@printf "  \033[36mdown\033[0m                   Stop and remove all containers\n"
	@printf "                         \033[2m$$ make down\033[0m\n"
	@printf "  \033[36mclean\033[0m                  Remove containers, networks, and volumes (wipes data!)\n"
	@printf "                         \033[2m$$ make clean\033[0m\n"
	@printf "  \033[36mps\033[0m                     Show status of all Radish containers\n"
	@printf "                         \033[2m$$ make ps\033[0m\n"
	@printf "  \033[36mlogs\033[0m                   Tail logs for all running containers\n"
	@printf "                         \033[2m$$ make logs\033[0m\n"
	@printf "  \033[36mstorage\033[0m                Show persistence file sizes (Docker server)\n"
	@printf "                         \033[2m$$ make storage\033[0m\n"
	@printf "\n"
	@printf "  \033[1m── Typical Workflows ──────────────────────────────────────────────\033[0m\n"
	@printf "  \033[2mRun everything in Docker (no local Julia):\033[0m\n"
	@printf "    $$ make build\n"
	@printf "    $$ make docker-test-all\n"
	@printf "    $$ make docker-bench-all\n"
	@printf "\n"
	@printf "  \033[2mBenchmark before/after a change:\033[0m\n"
	@printf "    $$ make docker-bench-all          # before\n"
	@printf "    $$ # ... make changes ...\n"
	@printf "    $$ make rebuild && make docker-bench-all  # after\n"
	@printf "    $$ make bench-diff BEFORE=benchmarks/results/docker_<ts1> AFTER=benchmarks/results/docker_<ts2>\n"
	@printf "\n"

.PHONY: build rebuild \
        server server-stop server-logs server-native \
        client client-native \
        simulator simload simrun simload-heavy simrun-heavy \
        test smoke-test test-all \
        docker-test docker-smoke-test docker-test-all \
        bench bench-system bench-net bench-net-native bench-all bench-full \
        docker-bench docker-bench-system docker-bench-net docker-bench-all \
        bench-compare bench-diff \
        validate docker-validate \
        docs docs-bg docs-stop docs-logs \
        down clean ps logs storage help
