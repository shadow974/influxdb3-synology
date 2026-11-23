#!/usr/bin/env bash
# Baut das InfluxDB-3-Image für die DS918+ auf einem x86_64-Linux-PC und
# exportiert es als .tar.gz für den Import im Synology Container Manager.
#
#   ./build.sh                     # Default: v3.12.3, x86-64-v2, release (LTO)
#   PROFILE=quick-release ./build.sh   # Build-PC mit < 16 GB RAM
#   TARGET_CPU=goldmont ./build.sh     # exakt auf J3455 optimiert
#   INFLUXDB_VERSION=v3.12.3 ./build.sh
#   PUSH_TO=ssh://admin@nas ./build.sh # zusätzlich direkt per SSH auf die NAS laden
set -euo pipefail
cd "$(dirname "$0")"

INFLUXDB_VERSION="${INFLUXDB_VERSION:-v3.12.3}"
TARGET_CPU="${TARGET_CPU:-x86-64-v2}"
PROFILE="${PROFILE:-release}"
CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-}"
VERIFY_CPU="${VERIFY_CPU:-Denverton-v2}"
TAG="${TAG:-influxdb3-core-dsm:${INFLUXDB_VERSION#v}}"
OUT="${OUT:-influxdb3-core-dsm-${INFLUXDB_VERSION#v}.tar.gz}"

mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)
if [ "$PROFILE" = "release" ] && [ "$mem_gb" -gt 0 ] && [ "$mem_gb" -lt 15 ]; then
  echo "Hinweis: nur ${mem_gb} GB RAM – fat-LTO-Linken kann scheitern."
  echo "         Ggf. mit PROFILE=quick-release oder CARGO_BUILD_JOBS=2 neu starten."
fi

echo ">> Baue ${TAG}  (InfluxDB ${INFLUXDB_VERSION}, target-cpu=${TARGET_CPU}, profile=${PROFILE})"
docker buildx build \
  --platform linux/amd64 \
  --build-arg INFLUXDB_VERSION="${INFLUXDB_VERSION}" \
  --build-arg TARGET_CPU="${TARGET_CPU}" \
  --build-arg PROFILE="${PROFILE}" \
  --build-arg CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS}" \
  --build-arg VERIFY_CPU="${VERIFY_CPU}" \
  --progress=plain \
  -t "${TAG}" \
  --load \
  .

echo ">> Exportiere nach ${OUT}"
docker save "${TAG}" | gzip -1 > "${OUT}"
ls -lh "${OUT}"

if [ -n "${PUSH_TO:-}" ]; then
  echo ">> Lade Image auf ${PUSH_TO}"
  host="${PUSH_TO#ssh://}"
  gunzip -c "${OUT}" | ssh "$host" 'sudo docker load'
fi

cat <<EOF

Fertig. Nächste Schritte auf der DS918+:
  1. Container Manager -> Image -> Hinzufügen -> Aus Datei hinzufügen -> ${OUT}
     (oder: scp ${OUT} admin@nas:/volume1/docker/ && ssh admin@nas 'sudo docker load -i /volume1/docker/${OUT}')
  2. Ordner /volume1/docker/influxdb3 anlegen, docker-compose.yml hineinkopieren
  3. Container Manager -> Projekt -> Erstellen -> Pfad /volume1/docker/influxdb3
  4. Admin-Token aus dem Log des Containers 'influxdb3' notieren
EOF
