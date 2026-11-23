#!/bin/bash
# Entrypoint für InfluxDB 3 Core auf Synology.
# - Erzeugt beim allerersten Start ein Admin-Token (offline) im Daten-Volume
#   und gibt es EINMALIG im Container-Log aus.
# - Prüft beim Start, ob die CPU die vom Binary benötigten Features hat.
# - Ersetzt ${VAR} in Argumenten (wie das Upstream-Entrypoint).
set -euo pipefail

BIN=/usr/bin/influxdb3

# --- CPU-Vorabprüfung -------------------------------------------------------
# Klare Fehlermeldung statt "Illegal instruction", falls jemand doch ein
# AVX2-Image (z.B. das offizielle) oder dieses Image auf zu alter CPU startet.
if [ -r /proc/cpuinfo ]; then
  flags=" $(grep -m1 '^flags' /proc/cpuinfo | cut -d: -f2) "
  missing=""
  for f in sse4_2 ssse3 popcnt cx16; do
    case "$flags" in *" $f "*) ;; *) missing="$missing $f";; esac
  done
  if [ -n "$missing" ]; then
    echo "FEHLER: CPU-Features fehlen:${missing} – dieses Image benötigt mindestens x86-64-v2." >&2
    exit 1
  fi
fi

if [ "${1:-}" = "serve" ] && [ -z "${INFLUXDB3_WITHOUT_AUTH:-}" ] \
   && [ -n "${INFLUXDB3_ADMIN_TOKEN_FILE:-}" ] && [ ! -s "${INFLUXDB3_ADMIN_TOKEN_FILE}" ]; then
  umask 077
  mkdir -p "$(dirname "$INFLUXDB3_ADMIN_TOKEN_FILE")"
  "$BIN" create token --admin --offline --output-file "$INFLUXDB3_ADMIN_TOKEN_FILE" >/dev/null
  chmod 600 "$INFLUXDB3_ADMIN_TOKEN_FILE"
  token=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$INFLUXDB3_ADMIN_TOKEN_FILE")
  cat <<EOF
==========================================================================
 Erststart: Admin-Token wurde erzeugt und gespeichert unter
   ${INFLUXDB3_ADMIN_TOKEN_FILE}
 (im Synology-Ordner: <volume>/secrets/admin-token.json)

   ${token}

 Bitte sicher aufbewahren (z.B. Passwortmanager). Dieses Token wird
 NICHT erneut angezeigt.
==========================================================================
EOF
fi

args=("$@")
for i in "${!args[@]}"; do
  args[$i]="$(printf '%s' "${args[$i]}" | envsubst)"
done

exec "$BIN" "${args[@]}"
