#!/usr/bin/env python3
"""
Formatea las respuestas JSON de las APIs de Prometheus, Alertmanager y Grafana
para el reporte de verify.sh.

Vive en un archivo propio y no incrustado en el script de shell: el codigo
Python dentro de comillas de bash obliga a escapar las comillas internas, y un
backslash dentro de una expresion de f-string es un error de sintaxis.

Uso:
    curl -s ... | python3 _report.py <seccion>

Secciones: targets, rules, query, alertmanagers, alerts, datasources,
           dashboards
"""

import json
import sys


def _cargar():
    """Lee JSON de la entrada estandar y aborta con un mensaje claro."""
    crudo = sys.stdin.read().strip()
    if not crudo:
        print("  [FALLA] la API no devolvio nada")
        sys.exit(0)
    try:
        return json.loads(crudo)
    except json.JSONDecodeError:
        print("  [FALLA] respuesta no valida de la API:")
        print("          " + crudo[:200])
        sys.exit(0)


def targets(d):
    activos = d.get("data", {}).get("activeTargets", [])
    if not activos:
        print("  [FALLA] Prometheus no tiene ningun target")
        return
    arriba = [t for t in activos if t.get("health") == "up"]
    for t in sorted(activos, key=lambda x: x.get("labels", {}).get("job", "")):
        etiquetas = t.get("labels", {})
        marca = "[OK]   " if t.get("health") == "up" else "[FALLA]"
        job = etiquetas.get("job", "?")
        instancia = etiquetas.get("instance", "?")
        print(f"  {marca} job={job:<22} instance={instancia:<24} "
              f"salud={t.get('health')}")
        if t.get("health") != "up" and t.get("lastError"):
            print(f"          error: {t['lastError']}")
    print(f"\n  TOTAL: {len(arriba)}/{len(activos)} targets en UP")
    app = [t for t in arriba if t.get("labels", {}).get("app") == "sre-app"]
    estado = "[OK]   " if len(app) == 2 else "[AVISO]"
    print(f"  {estado} pods de la aplicacion recolectados: {len(app)} "
          f"(se esperan 2)")


def rules(d):
    grupos = d.get("data", {}).get("groups", [])
    if not grupos:
        print("  [FALLA] no hay reglas cargadas")
        return
    total = 0
    for g in grupos:
        print(f"  grupo: {g.get('name')}")
        for r in g.get("rules", []):
            total += 1
            estado = r.get("state", "?")
            # 'inactive' es lo normal cuando la condicion no se cumple.
            print(f"    - {r.get('name'):<20} estado={estado}")
    marca = "[OK]   " if total == 6 else "[AVISO]"
    print(f"\n  {marca} TOTAL: {total} reglas cargadas (se esperan 6)")


def query(d):
    resultado = d.get("data", {}).get("result", [])
    if not resultado:
        print("  [AVISO] sin datos todavia: genera trafico con "
              "bash scripts/load-test.sh")
        return
    valor = float(resultado[0]["value"][1])
    print(f"  [OK]    hay datos: {valor:.4f} req/s")


def alertmanagers(d):
    activos = d.get("data", {}).get("activeAlertmanagers", [])
    if not activos:
        print("  [FALLA] Prometheus no tiene ningun Alertmanager activo")
        return
    for x in activos:
        print(f"  [OK]    {x.get('url')}")


def alerts(d):
    if not d:
        print("  (ninguna: normal si no has disparado alertas todavia)")
        return
    for a in d:
        etiquetas = a.get("labels", {})
        estado = a.get("status", {}).get("state", "?")
        print(f"  - {etiquetas.get('alertname')} "
              f"[{etiquetas.get('severity')}] estado={estado}")


def datasources(d):
    if not d:
        print("  [FALLA] Grafana no tiene datasources aprovisionados")
        return
    for x in d:
        print(f"  [OK]    {x.get('name')} ({x.get('type')}) -> "
              f"{x.get('url')}  default={x.get('isDefault')}")


def dashboards(d):
    if not d:
        print("  [FALLA] el dashboard no aparece en Grafana")
        return
    for x in d:
        carpeta = x.get("folderTitle", "General")
        print(f"  [OK]    {x.get('title')}  carpeta={carpeta}  "
              f"url={x.get('url')}")


SECCIONES = {
    "targets": targets,
    "rules": rules,
    "query": query,
    "alertmanagers": alertmanagers,
    "alerts": alerts,
    "datasources": datasources,
    "dashboards": dashboards,
}

if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in SECCIONES:
        print(f"uso: {sys.argv[0]} <{'|'.join(SECCIONES)}>", file=sys.stderr)
        sys.exit(2)
    SECCIONES[sys.argv[1]](_cargar())
