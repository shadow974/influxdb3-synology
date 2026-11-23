#!/usr/bin/env bash
# Prüft, ob ein influxdb3-Binary auf einer CPU ohne AVX/AVX2/BMI läuft,
# indem es unter QEMU-User-Emulation mit einem bestimmten CPU-Modell
# ausgeführt wird (Standard: Denverton = Goldmont, wie Celeron J3455 im DS918+).
#
#   verify-cpu.sh <pfad/zu/influxdb3> [QEMU-CPU-Modell]
#
# Exit 0 = OK, Exit 1 = "Illegal instruction" (Binary nutzt nicht vorhandene
# CPU-Befehle). Andere Startprobleme unter Emulation werden als Warnung
# gemeldet (VERIFY_STRICT=1 macht sie zu Fehlern).
set -uo pipefail

BIN="${1:?Pfad zum influxdb3-Binary fehlt}"
CPU="${2:-Denverton-v2}"
STRICT="${VERIFY_STRICT:-0}"
PORT="${VERIFY_PORT:-18181}"
QEMU=(qemu-x86_64 -cpu "$CPU")

command -v qemu-x86_64 >/dev/null || { echo "qemu-x86_64 fehlt (apt install qemu-user)"; exit 2; }

is_sigill() { [ "$1" -eq 132 ] || grep -qi "illegal instruction" "$2" 2>/dev/null; }

echo "== [1/2] '${BIN} --version' unter QEMU -cpu ${CPU}"
out=$(mktemp)
"${QEMU[@]}" "$BIN" --version >"$out" 2>&1; rc=$?
cat "$out"
if is_sigill "$rc" "$out"; then
  echo "FEHLER: Illegal instruction – das Binary läuft NICHT auf ${CPU} (DS918+)." >&2
  exit 1
elif [ "$rc" -ne 0 ]; then
  echo "WARNUNG: --version endete mit Code ${rc}" >&2
  [ "$STRICT" = 1 ] && exit 1
fi

echo "== [2/2] Server-Smoke-Test (Schreiben + SQL-Abfrage) unter QEMU -cpu ${CPU}"
work=$(mktemp -d)
log="$work/serve.log"
"${QEMU[@]}" "$BIN" serve --node-id verify --object-store file --data-dir "$work/data" \
    --http-bind "127.0.0.1:${PORT}" --without-auth --disable-telemetry-upload >"$log" 2>&1 &
pid=$!

cleanup() { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT

up=0
for _ in $(seq 1 180); do
  if ! kill -0 "$pid" 2>/dev/null; then break; fi
  if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then up=1; break; fi
  sleep 1
done

if [ "$up" -ne 1 ]; then
  wait "$pid" 2>/dev/null; rc=$?
  tail -n 40 "$log"
  if is_sigill "$rc" "$log"; then
    echo "FEHLER: Server-Start mit Illegal instruction abgebrochen." >&2
    exit 1
  fi
  echo "WARNUNG: Server unter Emulation nicht erreichbar (rc=${rc}) – kein CPU-Fehler erkannt." >&2
  [ "$STRICT" = 1 ] && exit 1
  exit 0
fi

ts=$(date +%s)000000000
curl -fsS -X POST "http://127.0.0.1:${PORT}/api/v3/write_lp?db=verify&precision=nanosecond" \
     --data-binary "cpu,host=ds918 usage=42.5,temp=51i ${ts}" || { tail -n 40 "$log"; exit 1; }
res=$(curl -fsS "http://127.0.0.1:${PORT}/api/v3/query_sql" \
     --data-urlencode "db=verify" \
     --data-urlencode "q=SELECT host, avg(usage) AS u, max(temp) AS t FROM cpu GROUP BY host" \
     --data-urlencode "format=json" -G) || { tail -n 40 "$log"; exit 1; }
echo "Abfrage-Ergebnis: $res"

if ! kill -0 "$pid" 2>/dev/null; then
  wait "$pid"; rc=$?
  tail -n 40 "$log"
  is_sigill "$rc" "$log" && { echo "FEHLER: Illegal instruction während Abfrage." >&2; exit 1; }
fi

echo "$res" | grep -Eq '"host" *: *"ds918"' || { echo "FEHLER: unerwartetes Abfrage-Ergebnis" >&2; exit 1; }
echo "OK: influxdb3 läuft auf CPU-Modell ${CPU} (kein AVX/AVX2/BMI nötig)."
