FROM julia:1.11

# Install netcat for Docker healthcheck
RUN apt-get update && apt-get install -y --no-install-recommends netcat-openbsd && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy project definition first (Manifest.toml excluded via .dockerignore)
COPY Project.toml ./

# Install dependencies (generates fresh Manifest for this Julia version)
RUN julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Copy source code (.dockerignore excludes .git, persistence/, Manifest.toml, etc.)
COPY . .

# Precompile dependencies (not the Radish module itself, which uses include() at runtime)
RUN julia --project=. -e 'using Pkg; Pkg.precompile(; warn_loaded=false)' || true

# Expose server port
EXPOSE 9000

# Metadata
LABEL description="Radish In-Memory Database Server"

# Run the server (0.0.0.0 to accept connections from other containers)
CMD ["julia", "--project=.", "server_runner.jl", "0.0.0.0", "9000"]
