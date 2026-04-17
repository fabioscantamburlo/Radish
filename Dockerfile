FROM julia:1.11

# Install netcat (healthcheck) + python3 (bench_net.py, smoke_test.py)
RUN apt-get update \
    && apt-get install -y --no-install-recommends netcat-openbsd python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ── Layer 1: Dependencies (cached until Project.toml changes) ────────────────
COPY Project.toml ./
RUN julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile(; warn_loaded=false)' || true

# ── Layer 2: Source code (rebuilt on any code change, but fast — just a copy) ─
COPY . .

EXPOSE 9000

LABEL description="Radish In-Memory Database Server"

CMD ["julia", "--threads=auto", "--project=.", "server_runner.jl", "0.0.0.0", "9000"]
