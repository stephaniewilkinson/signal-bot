# --- Stage 1: Build the Elixir release ---
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.4.1
ARG DEBIAN_VERSION=trixie-20260223

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS build

ENV MIX_ENV=prod

WORKDIR /app

RUN apt-get update -y && \
    apt-get install -y build-essential git && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

# Copy dependency files first for caching
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

COPY config/config.exs config/prod.exs config/runtime.exs config/
RUN mix deps.compile

# Copy application code and compile
COPY lib lib
COPY priv priv
RUN mix compile
RUN mix release

# --- Stage 2: Download Java + signal-cli (runs in parallel with Stage 1) ---
FROM ${RUNNER_IMAGE} AS downloads

ARG SIGNAL_CLI_VERSION=0.14.1

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends ca-certificates curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN curl -L -o /tmp/temurin.tar.gz \
      "https://api.adoptium.net/v3/binary/latest/25/ga/linux/x64/jre/hotspot/normal/eclipse" && \
    mkdir -p /opt/java && \
    tar xzf /tmp/temurin.tar.gz -C /opt/java --strip-components=1 && \
    rm /tmp/temurin.tar.gz

RUN curl -L -o /tmp/signal-cli.tar.gz \
      "https://github.com/AsamK/signal-cli/releases/download/v${SIGNAL_CLI_VERSION}/signal-cli-${SIGNAL_CLI_VERSION}.tar.gz" && \
    tar xzf /tmp/signal-cli.tar.gz -C /opt && \
    ln -s /opt/signal-cli-${SIGNAL_CLI_VERSION}/bin/signal-cli /usr/local/bin/signal-cli && \
    rm /tmp/signal-cli.tar.gz

# --- Stage 3: Runtime image ---
FROM ${RUNNER_IMAGE}

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

WORKDIR /app

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      libstdc++6 \
      openssl \
      libncurses6 \
      locales \
      ca-certificates \
      netcat-openbsd && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy pre-downloaded Java + signal-cli from downloads stage
COPY --from=downloads /opt/java /opt/java
COPY --from=downloads /opt/signal-cli-* /opt/signal-cli/
RUN ln -s /opt/signal-cli/bin/signal-cli /usr/local/bin/signal-cli
ENV JAVA_HOME=/opt/java
ENV PATH="$JAVA_HOME/bin:$PATH"

# Copy the Elixir release from the build stage
COPY --from=build /app/_build/prod/rel/yonderbook_clubs ./

# Copy the start script
COPY bin/start.sh /app/bin/start.sh
RUN chmod +x /app/bin/start.sh

# Create non-root user and data directory
RUN useradd -m appuser && \
    mkdir -p /data/signal-cli && \
    chown -R appuser: /app /data

USER appuser

CMD ["/app/bin/start.sh"]
