#!/bin/sh
# Auf der Synology (per SSH) ausführen:  sh check-cpu.sh
# Zeigt, welche x86-64-Stufe die CPU erfüllt und welches TARGET_CPU passt.
# POSIX-sh, läuft mit der Busybox/ash der DSM.

CPUINFO="${CPUINFO:-/proc/cpuinfo}"
cpu=$(grep -m1 'model name' "$CPUINFO" | cut -d: -f2 | sed 's/^ *//')
flags=" $(grep -m1 '^flags' "$CPUINFO" | cut -d: -f2) "
arch=$(uname -m)

has() { case "$flags" in *" $1 "*) return 0;; *) return 1;; esac; }
check() { # level, flags...
  lvl=$1; shift; miss=""
  for f in "$@"; do has "$f" || miss="$miss $f"; done
  if [ -z "$miss" ]; then printf '  %-10s OK\n' "$lvl"; return 0
  else printf '  %-10s fehlt:%s\n' "$lvl" "$miss"; return 1; fi
}

echo "CPU:        $cpu"
echo "Arch:       $arch"
echo "Kernel:     $(uname -r)"
echo "RAM:        $(awk '/MemTotal/ {printf "%.1f GB", $2/1024/1024}' /proc/meminfo)"
echo

if [ "$arch" != "x86_64" ]; then
  echo "Keine x86_64-CPU -> Image für linux/arm64 bauen (TARGET_CPU wird ignoriert)."
  exit 0
fi

echo "x86-64-Mikroarchitektur-Stufen:"
v2=1; v3=1
check x86-64-v2 cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3 || v2=0
check x86-64-v3 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave || v3=0
echo

if [ $v3 -eq 1 ]; then
  echo "=> CPU erfüllt x86-64-v3: das OFFIZIELLE Image (target-cpu=haswell) sollte laufen."
elif [ $v2 -eq 1 ]; then
  echo "=> CPU erfüllt nur x86-64-v2: offizielles Image stürzt ab ('Illegal instruction')."
  echo "   Eigenes Image bauen mit TARGET_CPU=x86-64-v2 (Default in build.sh)."
  case "$cpu" in *J3455*|*J3355*|*J4105*|*J4125*|*J4025*|*J4005*|*C3538*|*C3338*)
    echo "   Optional exakter: TARGET_CPU=goldmont" ;; esac
else
  echo "=> CPU erfüllt nicht einmal x86-64-v2: TARGET_CPU=x86-64 verwenden"
  echo "   (und in entrypoint.sh die Feature-Prüfung anpassen)."
fi
