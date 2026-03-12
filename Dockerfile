# --- Stage 1: Build the Elixir release ---
ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=28.4.1
ARG DEBIAN_VERSION=bookworm-20260223

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

# --- Stage 2: Runtime image ---
FROM ${RUNNER_IMAGE}

ARG SIGNAL_CLI_VERSION=0.14.1

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
      curl \
      netcat-openbsd \
      openjdk-21-jre-headless && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install signal-cli
RUN curl -L -o /tmp/signal-cli.tar.gz \
      "https://github.com/AsamK/signal-cli/releases/download/v${SIGNAL_CLI_VERSION}/signal-cli-${SIGNAL_CLI_VERSION}.tar.gz" && \
    tar xzf /tmp/signal-cli.tar.gz -C /opt && \
    ln -s /opt/signal-cli-${SIGNAL_CLI_VERSION}/bin/signal-cli /usr/local/bin/signal-cli && \
    rm /tmp/signal-cli.tar.gz

# Copy the Elixir release from the build stage
COPY --from=build /app/_build/prod/rel/yonderbook_clubs ./

# Copy the start script
COPY bin/start.sh /app/bin/start.sh
RUN chmod +x /app/bin/start.sh

# Create the data directory (will be overlaid by persistent disk on Render)
RUN mkdir -p /data/signal-cli

CMD ["/app/bin/start.sh"]
