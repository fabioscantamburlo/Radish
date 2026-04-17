FROM julia:1.11

# Install netcat (healthcheck) + python3 (bench_net.py, smoke_test.py)
RUN apt-get update \
    && apt-get install -y --no-install-recommends netcat-openbsd python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Julia dependencies first (cache layer)
COPY Project.toml ./
RUN julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Copy everything else
COPY . .

# Precompile dependencies
RUN julia --project=. -e 'using Pkg; Pkg.precompile(; warn_loaded=false)' || true

EXPOSE 9000

LABEL description="Radish In-Memory Database Server"

CMD ["julia", "--threads=auto", "--project=.", "server_runner.jl", "0.0.0.0", "9000"]
