# Build stage
FROM node:24-alpine AS builder

# Install build dependencies
RUN apk add --no-cache \
    curl \
    build-base \
    perl \
    llvm-dev \
    clang-dev

# Allow linking libclang on musl
ENV RUSTFLAGS="-C target-feature=-crt-static"

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

ARG POSTHOG_API_KEY
ARG POSTHOG_API_ENDPOINT

ENV VITE_PUBLIC_POSTHOG_KEY=$POSTHOG_API_KEY
ENV VITE_PUBLIC_POSTHOG_HOST=$POSTHOG_API_ENDPOINT

# Set working directory
WORKDIR /app

# Copy package files for dependency caching
COPY package*.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY frontend/package*.json ./frontend/
COPY npx-cli/package*.json ./npx-cli/

# Install pnpm and dependencies
RUN npm install -g pnpm && pnpm install

# Copy source code
COPY . .

# Build application
RUN npm run generate-types
RUN cd frontend && pnpm run build
RUN cargo build --release --bin server

# Runtime stage
FROM node:24-alpine AS runtime

# Install runtime dependencies
RUN apk add --no-cache \
    ca-certificates \
    tini \
    libgcc \
    wget \
    openssh-server \
    openssh-client \
    tmux

# Install AI CLI tools and clean up cache to reduce image size
RUN npm install -g @anthropic-ai/claude-code @openai/codex @google/gemini-cli && \
    npm cache clean --force && \
    rm -rf /root/.npm /tmp/*

# Configure SSH
RUN mkdir -p /run/sshd && \
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    echo 'root:vedyppah' | chpasswd && \
    ssh-keygen -A

RUN echo 'cd /home/appuser/' >> /root/.bashrc

# Create entrypoint script
RUN printf '#!/bin/sh\n\
    # Start SSHD\n\
    /usr/sbin/sshd\n\
    \n\
    # Start the application\n\
    exec tini -- server\n\
    ' > /usr/local/bin/entrypoint.sh && \
    chmod +x /usr/local/bin/entrypoint.sh

# Create app user for security
RUN addgroup -g 1001 -S appgroup && \
    adduser -u 1001 -S appuser -G appgroup

RUN apk add --no-cache git

# Copy binary from builder
COPY --from=builder /app/target/release/server /usr/local/bin/server

# Create repos directory and set permissions
RUN mkdir -p /repos && \
    chown -R appuser:appgroup /repos

# Set runtime environment
ENV HOST=0.0.0.0
ENV PORT=3000
EXPOSE 3000 22

# Set working directory
WORKDIR /repos

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --quiet --tries=1 --spider "http://${HOST:-localhost}:${PORT:-3000}" || exit 1

# Run the application (using root to start sshd, then app starts via tini)
# Note: In a production env, it's better to use a process manager like supervisor or a custom entrypoint that manages both
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

