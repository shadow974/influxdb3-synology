# InfluxDB 3 Core auf Synology DS918+

## Das Problem

Die DS918+ hat einen **Intel Celeron J3455** (Apollo Lake / Goldmont, 4 Kerne, 2016).
Er unterstützt SSE4.2, SSSE3, POPCNT, AES-NI, SHA – aber **kein AVX, AVX2, FMA, BMI1/BMI2**.

Die offiziellen InfluxDB-3-Builds werden mit `-C target-cpu=haswell` kompiliert
(`.cargo/config.toml` im Upstream-Repo). Damit enthält das Binary AVX2-/BMI2-Befehle
(z.B. `mulx`), und `influxdb:3-core` stirbt auf der DS918+ sofort mit
`Illegal instruction (core dumped)` – selbst bei `influxdb3 --version`.

## Die Lösung

Dieses Projekt baut InfluxDB 3 Core aus dem offiziellen Quellcode, ersetzt nur das
CPU-Ziel (`haswell` → `x86-64-v2`) und prüft das fertige Binary im Build per
QEMU-Emulation einer Goldmont-CPU (Modell `Denverton`): Server starten, Daten
schreiben, per SQL abfragen. Enthält das Binary einen nicht unterstützten Befehl,
schlägt der Build fehl.

| Datei | Zweck |
|---|---|
| `Dockerfile` | Multi-Stage-Build (Rust → debian-slim), inkl. Python Processing Engine |
| `build.sh` | Baut auf dem PC und exportiert `influxdb3-core-dsm-<ver>.tar.gz` |
| `docker-compose.yml` | Projekt für den Synology Container Manager |
| `check-cpu.sh` | Auf der NAS ausführen: zeigt, welche CPU-Stufe vorhanden ist |
| `scripts/entrypoint.sh` | Erstellt beim Erststart ein Admin-Token, CPU-Vorabprüfung |
| `scripts/verify-cpu.sh` | QEMU-Selbsttest (wird im Build ausgeführt) |

## 1. Bauen (auf einem x86_64-Linux-PC, nicht auf der NAS)

Voraussetzungen: Docker mit Buildx, Internet (GitHub, crates.io, Docker Hub),
~25 GB Plattenplatz, **≥ 16 GB RAM** für das Standard-Profil (fat LTO).
Dauer: je nach CPU 30–90 Minuten.

```bash
./build.sh
# Varianten:
PROFILE=quick-release ./build.sh          # Build-PC mit 8–16 GB RAM (etwas langsameres Binary)
CARGO_BUILD_JOBS=4 ./build.sh             # weniger Parallelität bei RAM-Knappheit
TARGET_CPU=goldmont ./build.sh            # exakt für J3455 (nicht portabel)
INFLUXDB_VERSION=v3.12.3 ./build.sh       # anderen Release-Tag bauen
```

Auf der DS918+ selbst zu bauen ist nicht sinnvoll: 4 GB RAM reichen für das Linken nicht,
und der J3455 bräuchte viele Stunden.

## 2. Auf die DS918+ bringen

**Container Manager → Image → Hinzufügen → Aus Datei hinzufügen** → `influxdb3-core-dsm-3.12.3.tar.gz`

oder per SSH:

```bash
scp influxdb3-core-dsm-3.12.3.tar.gz admin@ds918:/volume1/docker/
ssh admin@ds918 'sudo docker load -i /volume1/docker/influxdb3-core-dsm-3.12.3.tar.gz'
```

Optional vorher auf der NAS prüfen: `sh check-cpu.sh`

## 3. Starten

1. In File Station den Ordner `/volume1/docker/influxdb3` anlegen und `docker-compose.yml` hineinlegen.
2. **Container Manager → Projekt → Erstellen**, Pfad `/volume1/docker/influxdb3`, „vorhandene docker-compose.yml verwenden“.
3. Der Container `influxdb3` setzt beim Start selbst die Rechte (UID 1500) auf `data/` und `plugins/` und läuft danach als `influxdb3` – es gibt keinen separaten Helfer-Container.
4. Im **Log des Containers `influxdb3`** steht beim Erststart das **Admin-Token** (`apiv3_…`).
   Es liegt außerdem in `/volume1/docker/influxdb3/data/secrets/admin-token.json`.

Test:

```bash
TOKEN=apiv3_...
curl http://ds918:8181/health
curl -X POST "http://ds918:8181/api/v3/write_lp?db=haus" -H "Authorization: Bearer $TOKEN" \
     --data-binary 'temp,raum=keller wert=12.5'
curl -G "http://ds918:8181/api/v3/query_sql" -H "Authorization: Bearer $TOKEN" \
     --data-urlencode "db=haus" --data-urlencode "q=SELECT * FROM temp"
```

## Ressourcen / Tuning (DS918+: 4 Kerne, 4 GB RAM ab Werk, max. 8 GB)

In `docker-compose.yml` voreingestellt, per `.env` im Projektordner überschreibbar:

| Variable | Default | Bedeutung |
|---|---|---|
| `INFLUXDB3_MEM_LIMIT` | `2g` | Container-RAM-Limit (InfluxDB richtet %-Werte daran aus, cgroup-aware) |
| `INFLUXDB3_NUM_DATAFUSION_THREADS` | `3` | Query-Threads, 1 Kern bleibt für DSM |
| `INFLUXDB3_EXEC_MEM_POOL_SIZE` | `20%` | Speicherbudget pro Abfrageausführung |
| `INFLUXDB3_FORCE_SNAPSHOT_MEM_SIZE` | `30%` | Write-Buffer, ab dem ein Snapshot erzwungen wird |
| `INFLUXDB3_PORT` | `8181` | Port auf der NAS |

## Hinweise

- **InfluxDB 3 Core** ist für aktuelle Daten optimiert; ältere Daten werden als Parquet
  unter `data/` abgelegt. Hyper-Backup des Ordners `/volume1/docker/influxdb3` genügt als Backup
  (am besten bei gestopptem Container).
- **Updates:** `INFLUXDB_VERSION=v3.x.y ./build.sh`, Image importieren, im Projekt die
  Image-Version anpassen (`INFLUXDB3_IMAGE`) und neu erstellen. Bricht der Build mit
  „target-cpu=haswell nicht gefunden“ ab, hat Upstream die Build-Konfiguration geändert –
  dann `.cargo/config.toml` im neuen Tag prüfen.
- Das Image enthält eine CPU-Prüfung im Entrypoint: Fehlt `sse4_2/ssse3/popcnt/cx16`,
  bricht der Start mit klarer Meldung ab statt mit „Illegal instruction“.
- Lizenz InfluxDB 3 Core: MIT/Apache-2.0.
