#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Requiere root
if [ "$(id -u)" -ne 0 ]; then
  echo "Este script debe ejecutarse como root" >&2
  exit 1
fi

echo "=================================================================="
echo "  INSTALACIÓN DE MINI SIERVOS BLINDADOS — ORTOTECNIK             "
echo "=================================================================="

# Helper para ejecutar pct exec sin abortar todo si falla (registro)
pct_safe_exec() {
  local CT="$1"; shift
  if ! pct exec "$CT" -- "$@" ; then
    echo "WARNING: pct exec en CT $CT falló (no abortando). Comando: $*"
    return 1
  fi
}

# ══════════════════════════════════════════════════════════════
# MINI SIERVO 1: ASEO DEL HOST (Diario 03:00 AM)
# ══════════════════════════════════════════════════════════════
echo "=== 1. Creando Mini Siervo del Host ==="
cat > /usr/local/sbin/orto-aseo-host.sh <<'HOSTCLEAN'
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

LOG="/var/log/orto-aseo-host.log"
mkdir -p "$(dirname "$LOG")"
echo "[$(date '+%Y-%m-%d %H:%M')] Inicio de aseo" >> "$LOG" || true

# 1. Journald: limitar a 50 MB y eliminar diarios corruptos (.journal~)
journalctl --vacuum-size=50M >> "$LOG" 2>&1 || true
CORRUPTOS=$(find /var/log/journal/ -name "*.journal~" 2>/dev/null | wc -l || echo 0)
if [ "${CORRUPTOS:-0}" -gt 0 ]; then
    find /var/log/journal/ -name "*.journal~" -delete 2>/dev/null || true
    echo "  Eliminados $CORRUPTOS diarios corruptos" >> "$LOG"
fi

# 2. Chromium: limpiar crash reports viejos (> 3 dias) sin tocar perfil activo
if [ -d "/root/.config/chromium/Crash Reports" ]; then
    find "/root/.config/chromium/Crash Reports" -type f -mtime +3 -delete 2>/dev/null || true
    echo "  Crash Reports limpiados" >> "$LOG"
fi

# 3. Temporales: solo archivos de impresion con MAS de 2 horas de antiguedad
find /tmp -maxdepth 1 \( -name "ticket*" -o -name "orden*" -o -name "chrome_p_*" -o -name "c_tmp*" \) -mmin +120 -delete 2>/dev/null || true
echo "  Temporales viejos limpiados" >> "$LOG"

# 4. Limpiar paquetes .deb descargados (NO desinstala nada)
apt-get clean >> "$LOG" 2>&1 || true

# 5. Rotar el propio log de aseo si supera 1 MB (mantener últimas 100 líneas)
if [ -f "$LOG" ]; then
    LOG_SIZE=$(stat -c%s "$LOG" 2>/dev/null || echo "0")
    if [ "$LOG_SIZE" -gt 1048576 ]; then
        tail -n 100 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
    fi
fi

echo "[$(date '+%Y-%m-%d %H:%M')] Aseo completado" >> "$LOG"
HOSTCLEAN
chmod +x /usr/local/sbin/orto-aseo-host.sh

# Crear servicio systemd (unit más completa)
cat > /etc/systemd/system/orto-aseo-host.service <<'SVC'
[Unit]
Description=Mini Siervo de Aseo Host Ortotecnik (Diario)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/orto-aseo-host.sh
Nice=19
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
SVC

# Crear timer systemd (Diario 03:00 AM)
cat > /etc/systemd/system/orto-aseo-host.timer <<'TMR'
[Unit]
Description=Timer Diario Mini Siervo Host Ortotecnik (03:00 AM)

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
TMR

echo "  [+] orto-aseo-host.sh creado"
echo "  [+] orto-aseo-host.timer creado (03:00 AM diario)"

# ══════════════════════════════════════════════════════════════
# MINI SIERVO 2: ASEO DE ERPNEXT CT 101 (Semanal Domingo 03:30 AM)
# ══════════════════════════════════════════════════════════════
echo -e "\n=== 2. Creando Mini Siervo de ERPNext (CT 101) ==="
pct_safe_exec 101 bash -c 'cat > /usr/local/sbin/orto-aseo-erpnext.sh <<'"'"'CT101CLEAN'"'"''
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

LOG="/var/log/orto-aseo-erpnext.log"
mkdir -p "$(dirname "$LOG")"
echo "[$(date '+%Y-%m-%d %H:%M')] Inicio de aseo ERPNext" >> "$LOG" || true

# 1. Purgar Error Log y Sessions viejas en MariaDB (sin tocar cache de Redis)
# Usamos un heredoc Python para evitar problemas de comillas y para comprobar sitios
/opt/frappe-bench/env/bin/python3 <<'PY' >> "$LOG" 2>&1
import os
import sys
sys.path.insert(0, "/opt/frappe-bench/apps/frappe")
os.chdir("/opt/frappe-bench/sites")
import frappe

sites = [s for s in os.listdir(".") if os.path.isdir(s) and os.path.exists(os.path.join(s, "site_config.json"))]
if not sites:
    print("No se encontraron sitios en /opt/frappe-bench/sites", file=sys.stderr)
    sys.exit(0)

# Operar en el primer sitio (o adaptar según tu política)
site = sites[0]
frappe.init(site=site)
frappe.connect()

# Borrar errores de mas de 14 dias
frappe.db.sql("DELETE FROM `tabError Log` WHERE creation < NOW() - INTERVAL 14 DAY")
# Borrar sesiones abandonadas de mas de 7 dias
frappe.db.sql("DELETE FROM `tabSessions` WHERE lastupdate < NOW() - INTERVAL 7 DAY")
# Borrar logs de actividad y acceso viejos
frappe.db.sql("DELETE FROM `tabActivity Log` WHERE creation < NOW() - INTERVAL 30 DAY")
frappe.db.sql("DELETE FROM `tabAccess Log` WHERE creation < NOW() - INTERVAL 30 DAY")

frappe.db.commit()
frappe.destroy()
PY

# 2. Rotar logs de bench de forma segura (copiar y vaciar, no truncar)
for logfile in /opt/frappe-bench/logs/*.log; do
    if [ -f "$logfile" ]; then
        SIZE=$(stat -c%s "$logfile" 2>/dev/null || echo "0")
        # Solo rotar si supera 25 MB
        if [ "$SIZE" -gt 26214400 ]; then
            tail -n 1000 "$logfile" > "${logfile}.rotated"
            : > "$logfile"
            mv "${logfile}.rotated" "${logfile}.bak"
            echo "  Rotado: $(basename "$logfile") (era ${SIZE} bytes)" >> "$LOG"
        fi
    fi
done

# 3. Rotar el propio log
if [ -f "$LOG" ]; then
    LOG_SIZE=$(stat -c%s "$LOG" 2>/dev/null || echo "0")
    if [ "$LOG_SIZE" -gt 1048576 ]; then
        tail -n 100 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
    fi
fi

echo "[$(date '+%Y-%m-%d %H:%M')] Aseo completado" >> "$LOG"
CT101CLEAN' || true

# Hacer ejecutable dentro del contenedor (pct exec puede fallar si CT no existe)
pct_safe_exec 101 chmod +x /usr/local/sbin/orto-aseo-erpnext.sh || true

# Instalar cron semanal en CT 101 (Domingo 03:30 AM) sin duplicar
pct_safe_exec 101 bash -c '(crontab -l 2>/dev/null | grep -v "orto-aseo-erpnext" || true; echo "30 3 * * 0 /usr/local/sbin/orto-aseo-erpnext.sh") | crontab -' || true
echo "  [+] orto-aseo-erpnext.sh creado en CT 101 (si el CT existe)"
echo "  [+] Cron semanal instalado (Domingo 03:30 AM) (si el CT existe)"

# ══════════════════════════════════════════════════════════════
# MINI SIERVO 3: ASEO DE DOCKER CT 100 (Quincenal Día 1 y 15 a 04:00 AM)
# ══════════════════════════════════════════════════════════════
# Nota: en el script original comentabas "Quincenal Domingo 04:00 AM" pero el cron 1,15 es por día del mes.
# Decide si quieres 1 y 15 (se hace ahora) o "cada dos semanas los domingos" y lo ajusto.
echo -e "\n=== 3. Creando Mini Siervo de Docker (CT 100) ==="
pct_safe_exec 100 bash -c 'cat > /usr/local/sbin/orto-aseo-docker.sh <<'"'"'CT100CLEAN'"'"''
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

LOG="/var/log/orto-aseo-docker.log"
mkdir -p "$(dirname "$LOG")"
echo "[$(date '+%Y-%m-%d %H:%M')] Inicio de aseo Docker" >> "$LOG" || true

# 1. Purgar build cache (capas de compilacion viejas)
docker builder prune -f >> "$LOG" 2>&1 || true

# 2. Eliminar imagenes dangling (sin tag, huerfanas)
DANGLING=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l || echo 0)
if [ "${DANGLING:-0}" -gt 0 ]; then
    docker images -f "dangling=true" -q | xargs -r docker rmi -f >> "$LOG" 2>&1 || true
    echo "  Eliminadas $DANGLING imagenes huerfanas" >> "$LOG"
fi

# 3. Limpiar logs de contenedores que superen 50 MB
for LOGFILE in /var/lib/docker/containers/*/*.log; do
    if [ -f "$LOGFILE" ]; then
        SIZE=$(stat -c%s "$LOGFILE" 2>/dev/null || echo "0")
        if [ "$SIZE" -gt 52428800 ]; then
            : > "$LOGFILE"
            echo "  Vaciado log de contenedor (era $SIZE bytes)" >> "$LOG"
        fi
    fi
done

# 4. Rotar propio log
if [ -f "$LOG" ]; then
    LOG_SIZE=$(stat -c%s "$LOG" 2>/dev/null || echo "0")
    if [ "$LOG_SIZE" -gt 1048576 ]; then
        tail -n 100 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
    fi
fi

echo "[$(date '+%Y-%m-%d %H:%M')] Aseo Docker completado" >> "$LOG"
CT100CLEAN' || true

pct_safe_exec 100 chmod +x /usr/local/sbin/orto-aseo-docker.sh || true

# Instalar cron en CT 100: 1 y 15 del mes a 04:00 AM (sin duplicar)
pct_safe_exec 100 bash -c '(crontab -l 2>/dev/null | grep -v "orto-aseo-docker" || true; echo "0 4 1,15 * * /usr/local/sbin/orto-aseo-docker.sh") | crontab -' || true
echo "  [+] orto-aseo-docker.sh creado en CT 100 (si el CT existe)"
echo "  [+] Cron quincenal instalado (Día 1 y 15, 04:00 AM) (si el CT existe)"

# ══════════════════════════════════════════════════════════════
# ACTIVACIÓN Y PRIMERA EJECUCIÓN
# ══════════════════════════════════════════════════════════════
echo -e "\n=== 4. Activando timers y ejecutando primera pasada ==="
systemctl daemon-reload
systemctl enable --now orto-aseo-host.timer || true

echo -e "\n--- Ejecutando primera limpieza inmediata del Host ---"
if /usr/local/sbin/orto-aseo-host.sh 2>/dev/null; then
    cat /var/log/orto-aseo-host.log || true
else
    echo "ERROR: ejecución inicial orto-aseo-host.sh falló (revisar logs)" >&2
fi

echo -e "\n--- Ejecutando primera limpieza de ERPNext (CT 101) ---"
pct_safe_exec 101 /usr/local/sbin/orto-aseo-erpnext.sh || true
pct_safe_exec 101 cat /var/log/orto-aseo-erpnext.log || true

echo -e "\n--- Ejecutando primera limpieza de Docker (CT 100) ---"
pct_safe_exec 100 /usr/local/sbin/orto-aseo-docker.sh || true
pct_safe_exec 100 cat /var/log/orto-aseo-docker.log || true

# ══════════════════════════════════════════════════════════════
# VERIFICACIÓN FINAL
# ══════════════════════════════════════════════════════════════
echo -e "\n=== 5. VERIFICACIÓN DE MINI SIERVOS ACTIVOS ==="
echo "--- Timers del Host ---"
systemctl list-timers | grep orto-aseo || systemctl list-timers --no-pager | true

echo -e "\n--- Cron de CT 101 ---"
pct_safe_exec 101 crontab -l || true

echo -e "\n--- Cron de CT 100 ---"
pct_safe_exec 100 crontab -l || true

echo -e "\n=================================================================="
echo "  MINI SIERVOS DESPLEGADOS Y VERIFICADOS (si los CTs existen)"
echo ""
echo "  Host:    orto-aseo-host.timer    → Diario 03:00 AM"
echo "  CT 101:  orto-aseo-erpnext.sh    → Domingo 03:30 AM"
echo "  CT 100:  orto-aseo-docker.sh     → Día 1 y 15, 04:00 AM"
echo ""
echo "  Logs de auditoría:"
echo "    Host:    /var/log/orto-aseo-host.log"
echo "    CT 101:  /var/log/orto-aseo-erpnext.log"
echo "    CT 100:  /var/log/orto-aseo-docker.log"
echo "=================================================================="
