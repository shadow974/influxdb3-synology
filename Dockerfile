# syntax=docker/dockerfile:1.7
#
# InfluxDB 3 Core – gebaut für Synology DS918+ (Intel Celeron J3455, "Goldmont")
#
# Warum ein eigener Build?
#   Die offiziellen InfluxDB-3-Binaries/Images werden mit
#   `-C target-cpu=haswell` kompiliert (siehe .cargo/config.toml im Upstream-Repo).
#   Damit setzen sie AVX, AVX2, FMA, BMI1/BMI2 (z.B. `mulx`) usw. voraus.
#   Der J3455 hat KEIN AVX/AVX2/BMI -> das offizielle Image stirbt sofort mit
#   "Illegal instruction (core dumped)".
#
#   Dieser Build ersetzt das Ziel durch eine CPU-Stufe, die der J3455 kann
#   (Standard: x86-64-v2 = SSE4.2/SSSE3/POPCNT/CX16), und prüft das Ergebnis
#   am Ende per QEMU-Emulation einer Goldmont-CPU (Modell "Denverton").
#
# Build (auf einem x86_64-Linux-PC mit >= 16 GB RAM, NICHT auf der NAS):
#   docker buildx build --platform linux/amd64 -t influxdb3-core:3.12.3-dsm --load .
#
# ---------------------------------------------------------------------------

ARG DEBIAN_RELEASE=bookworm

############################
# Stage 1: Build
############################
FROM rust:1-slim-${DEBIAN_RELEASE} AS build

# --- Build-Parameter --------------------------------------------------------
# Git-Tag von https://github.com/influxdata/influxdb
ARG INFLUXDB_VERSION=v3.12.3
# CPU-Ziel für rustc. Für den DS918+ geeignet:
#   x86-64-v2  (Default, portabel: läuft auf jeder x86-NAS ab ~2009/Atom C2000)
#   goldmont   (exakt J3455/J4105-Klasse, minimal schneller, nicht portabel)
# NICHT verwenden: haswell, x86-64-v3, native (wenn der Build-PC AVX2 hat)
ARG TARGET_CPU=x86-64-v2
# release = fat LTO (schnellstes Binary, braucht ~16-24 GB RAM beim Linken)
# quick-release = kein LTO (Build-PC mit 8-16 GB RAM)
ARG PROFILE=release
# Parallele Jobs begrenzen, falls der Build-PC wenig RAM hat (leer = alle Kerne)
ARG CARGO_BUILD_JOBS=
# Features wie im Upstream-Default (inkl. jemalloc, S3/GCS/Azure-Object-Store)
ARG FEATURES=jemalloc_replacing_malloc,aws,gcp,azure,large-strings
# QEMU-CPU-Modell für den Selbsttest (Denverton = Goldmont-Mikroarchitektur
# wie im J3455). Leer lassen, um den Test zu überspringen.
ARG VERIFY_CPU=Denverton-v2

USER root
# libprotobuf-dev liefert die Well-Known-Types (google/protobuf/*.proto), die
# protoc braucht. protobuf-compiler zieht es nur als "Recommends" nach, was
# --no-install-recommends unterdrückt -> "timestamp.proto: File not found".
RUN apt-get update \
 && apt-get install --yes --no-install-recommends \
      binutils build-essential ca-certificates curl git pkg-config libssl-dev \
      clang lld patchelf protobuf-compiler libprotobuf-dev zstd libz-dev \
      qemu-user \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /influxdb3
RUN git -c advice.detachedHead=false clone --depth 1 --branch "${INFLUXDB_VERSION}" \
      https://github.com/influxdata/influxdb.git .

# --- CPU-Ziel patchen -------------------------------------------------------
# Upstream: "-C", "target-cpu=haswell"  ->  "-C", "target-cpu=${TARGET_CPU}"
# Bricht ab, falls Upstream die Datei ändert (damit nie still ein AVX2-Binary
# entsteht).
RUN set -eu; \
    case "${TARGET_CPU}" in \
      haswell|native|x86-64-v3|x86-64-v4|skylake*|znver*) \
        echo "FEHLER: TARGET_CPU=${TARGET_CPU} setzt AVX2 voraus und läuft NICHT auf dem DS918+." >&2; exit 1;; \
    esac; \
    grep -q '"target-cpu=haswell"' .cargo/config.toml \
      || { echo "FEHLER: target-cpu=haswell nicht in .cargo/config.toml gefunden – Upstream hat sich geändert, bitte prüfen." >&2; exit 1; }; \
    sed -i "s/\"target-cpu=haswell\"/\"target-cpu=${TARGET_CPU}\"/" .cargo/config.toml; \
    echo "== .cargo/config.toml (gepatcht) =="; grep -n 'target-cpu' .cargo/config.toml

# --- Python-Build-Standalone für die Processing Engine (wie Upstream) -------
# Version/Datum werden aus der CircleCI-Config des gewählten Tags gelesen.
# Das PBS-Target "x86_64-unknown-linux-gnu" ist x86-64-v1 -> J3455-tauglich.
ARG PBS_TARGET=x86_64-unknown-linux-gnu
RUN set -eu; \
    PBS_DATE=$(grep -A2 '^  PBS_DATE:' .circleci/config.yml | sed -n 's/.*default: "\(.*\)"/\1/p'); \
    PBS_VERSION=$(grep -A2 '^  PBS_VERSION:' .circleci/config.yml | sed -n 's/.*default: "\(.*\)"/\1/p'); \
    echo "Python-Build-Standalone: ${PBS_VERSION} (${PBS_DATE})"; \
    test -n "$PBS_DATE" && test -n "$PBS_VERSION"; \
    sed -i "s/^readonly TARGETS=.*/readonly TARGETS=${PBS_TARGET}/" ./.circleci/scripts/fetch-python-standalone.bash; \
    ./.circleci/scripts/fetch-python-standalone.bash /influxdb3/python-artifacts "${PBS_DATE}" "${PBS_VERSION}"; \
    tar -C /influxdb3/python-artifacts -zxf /influxdb3/python-artifacts/all.tar.gz "./${PBS_TARGET}"; \
    sed -i 's#tmp/workspace#influxdb3#' "/influxdb3/python-artifacts/${PBS_TARGET}/pyo3_config_file.txt"; \
    cat "/influxdb3/python-artifacts/${PBS_TARGET}/pyo3_config_file.txt"

# --- Kompilieren --------------------------------------------------------------
# rust-toolchain.toml im Repo pinnt die Rust-Version; rustup installiert sie.
RUN --mount=type=cache,id=influxdb3_rustup,sharing=locked,target=/usr/local/rustup \
    --mount=type=cache,id=influxdb3_registry,sharing=locked,target=/usr/local/cargo/registry \
    --mount=type=cache,id=influxdb3_git,sharing=locked,target=/usr/local/cargo/git \
    --mount=type=cache,id=influxdb3_target_dsm,sharing=locked,target=/influxdb3/target \
    set -eu; \
    rustup toolchain install; \
    rustc --version; \
    if [ -z "${CARGO_BUILD_JOBS}" ]; then unset CARGO_BUILD_JOBS; fi; \
    PYO3_CONFIG_FILE="/influxdb3/python-artifacts/${PBS_TARGET}/pyo3_config_file.txt" \
      cargo build --locked --package influxdb3 --profile "${PROFILE}" \
                  --no-default-features --features "${FEATURES}"; \
    objcopy --compress-debug-sections "target/${PROFILE}/influxdb3"; \
    cp "target/${PROFILE}/influxdb3" /root/influxdb3; \
    patchelf --set-rpath '$ORIGIN/python/lib:$ORIGIN/../lib/influxdb3/python/lib' /root/influxdb3; \
    cp -a "/influxdb3/python-artifacts/${PBS_TARGET}/python" /root/python

# --- Selbsttest: läuft das Binary auf einer CPU OHNE AVX/AVX2/BMI? -----------
# Startet den Server unter QEMU mit Goldmont-CPU-Modell, schreibt Daten und
# fragt sie per SQL ab. Ein "Illegal instruction" lässt den Build scheitern.
COPY scripts/verify-cpu.sh /usr/local/bin/verify-cpu.sh
RUN set -eu; \
    if [ -z "${VERIFY_CPU}" ]; then echo "VERIFY_CPU leer – Selbsttest übersprungen"; exit 0; fi; \
    mkdir -p /root/lib/influxdb3 && ln -sfn /root/python /root/lib/influxdb3/python; \
    bash /usr/local/bin/verify-cpu.sh /root/influxdb3 "${VERIFY_CPU}"

############################
# Stage 2: Runtime
############################
FROM debian:${DEBIAN_RELEASE}-slim

ARG INFLUXDB_VERSION=v3.12.3
ARG TARGET_CPU=x86-64-v2
LABEL org.opencontainers.image.title="InfluxDB 3 Core (Synology DS918+ / ohne AVX2)" \
      org.opencontainers.image.version="${INFLUXDB_VERSION}" \
      org.opencontainers.image.source="https://github.com/influxdata/influxdb" \
      org.opencontainers.image.licenses="MIT OR Apache-2.0" \
      de.redmedical.target-cpu="${TARGET_CPU}"

RUN apt-get update \
 && apt-get install --yes --no-install-recommends ca-certificates gettext-base libssl3 curl tini \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 1500 influxdb3 \
 && useradd --uid 1500 --gid influxdb3 --shell /bin/bash --create-home influxdb3 \
 && mkdir -p /var/lib/influxdb3 /plugins /usr/lib/influxdb3 \
 && chown influxdb3:influxdb3 /var/lib/influxdb3 /plugins

COPY --from=build /root/python /usr/lib/influxdb3/python
COPY --from=build /root/influxdb3 /usr/bin/influxdb3
COPY scripts/entrypoint.sh /usr/bin/entrypoint.sh
RUN chmod 0755 /usr/bin/entrypoint.sh && /usr/bin/influxdb3 --version

USER influxdb3

# Sinnvolle Defaults für eine NAS mit lokalem Volume
ENV INFLUXDB3_OBJECT_STORE=file \
    INFLUXDB3_DATA_DIR=/var/lib/influxdb3/data \
    INFLUXDB3_NODE_ID=ds918 \
    INFLUXDB3_PLUGIN_DIR=/plugins \
    INFLUXDB3_ADMIN_TOKEN_FILE=/var/lib/influxdb3/secrets/admin-token.json \
    INFLUXDB3_DISABLE_AUTHZ=health,ping \
    INFLUXDB3_LOG_FILTER=info

VOLUME ["/var/lib/influxdb3", "/plugins"]
EXPOSE 8181

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8181/health >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/bin/entrypoint.sh"]
CMD ["serve"]
