# Arquitectura

## Diagrama de componentes

```
                        ┌──────────────────────────┐
                        │   Navegador del usuario  │
                        └────────────┬─────────────┘
                                     │ NodePort / port-forward
   ┌─────────────────────────────────┼─────────────────────────────────┐
   │ Cluster Kubernetes (Minikube)   │                                 │
   │                                 │                                 │
   │  ┌───────────── namespace: sre-app ──────────────┐                │
   │  │                                               │                │
   │  │   ┌─────────────┐      ┌─────────────┐        │                │
   │  │   │  sre-app    │      │  sre-app    │        │                │
   │  │   │  pod 1      │      │  pod 2      │        │                │
   │  │   │  :5000      │      │  :5000      │        │                │
   │  │   │  /metrics   │      │  /metrics   │        │                │
   │  │   └──────┬──────┘      └──────┬──────┘        │                │
   │  └──────────┼────────────────────┼───────────────┘                │
   │             │   scrape cada 15s  │                                │
   │             │  (service discovery por anotaciones)                │
   │  ┌──────────┴────── namespace: monitoring ───────┴─────────────┐  │
   │  │                                                             │  │
   │  │   ┌──────────────┐  evalua reglas  ┌──────────────────┐     │  │
   │  │   │  Prometheus  ├────────────────>│  Alertmanager    │     │  │
   │  │   │  :9090       │   alertas       │  :9093           │     │  │
   │  │   │              │                 │  agrupa, enruta  │     │  │
   │  │   └──────┬───────┘                 └────────┬─────────┘     │  │
   │  │          │ consultas PromQL                 │ webhook       │  │
   │  │          v                                  v               │  │
   │  │   ┌──────────────┐                 ┌──────────────────┐     │  │
   │  │   │  Grafana     │                 │  alert-logger    │     │  │
   │  │   │  :3000       │                 │  :8080           │     │  │
   │  │   │  dashboards  │                 │  (y opcional     │     │  │
   │  │   │  por codigo  │                 │   Slack / email) │     │  │
   │  │   └──────────────┘                 └──────────────────┘     │  │
   │  └─────────────────────────────────────────────────────────────┘  │
   └───────────────────────────────────────────────────────────────────┘
```

## Flujo de datos

1. **Generacion.** La aplicacion Flask incrementa contadores e histogramas en
   memoria con `prometheus_client` y los expone en texto plano en `/metrics`.

2. **Recoleccion (modelo pull).** Prometheus consulta la API de Kubernetes
   para descubrir pods con la anotacion `prometheus.io/scrape: "true"` y hace
   una peticion HTTP a cada `/metrics` cada 15 segundos. La aplicacion no
   necesita saber que Prometheus existe: ahi esta la ventaja del modelo pull
   sobre el push.

3. **Almacenamiento.** Las muestras se guardan en la base de series temporales
   local de Prometheus, con 6 horas de retencion en este entorno.

4. **Evaluacion.** Cada 15 segundos Prometheus reevalua las reglas de
   `prometheus-rules`. Si una expresion se mantiene verdadera durante el
   tiempo del campo `for`, la alerta pasa de `pending` a `firing`.

5. **Enrutamiento.** Las alertas en estado `firing` se envian a Alertmanager,
   que las agrupa por `alertname` y `service`, aplica las reglas de inhibicion
   y las entrega al receptor correspondiente segun la severidad.

6. **Visualizacion.** Grafana consulta a Prometheus con PromQL y pinta el
   dashboard de Golden Signals.

## Decisiones de diseno

**Dos namespaces en lugar de uno.** Separar `sre-app` de `monitoring` refleja
la division real de responsabilidades: plataforma administra el stack de
observabilidad, producto administra la aplicacion. Tambien permite aplicar
cuotas y politicas de red distintas a cada uno.

**Service discovery por anotaciones, no targets estaticos.** Los pods cambian
de IP cada vez que se reinician. Una lista fija de IPs en `prometheus.yml` se
rompe en el primer rollout. Con anotaciones, cualquier equipo puede sumar su
servicio al monitoreo sin tocar la configuracion de Prometheus.

**Histograma y no resumen para la latencia.** Un `Histogram` permite calcular
percentiles agregados entre varias replicas con `histogram_quantile()`. Un
`Summary` calcula los percentiles en cada pod por separado y esos valores no
se pueden sumar entre instancias de forma matematicamente valida.

**`clamp_min()` en los divisores.** Cuando no hay trafico, el denominador de
la tasa de error es cero y la expresion devuelve `NaN`, lo que deja el panel
vacio y puede provocar alertas erraticas. `clamp_min(..., 0.001)` evita la
division por cero.

**`for:` en todas las alertas.** Sin ese campo, un unico scrape anomalo
dispara una notificacion. El `for` exige que la condicion persista, que es la
diferencia entre una alerta util y una alerta que el equipo aprende a ignorar.

**Alertmanager con webhook local por defecto.** El receptor incluido escribe
las alertas en sus logs, de modo que el flujo completo se puede demostrar y
reproducir sin configurar credenciales. Slack y correo quedan como plantillas
listas para activar.

**`emptyDir` en lugar de PersistentVolume.** En un entorno de practica la
perdida de datos al reiniciar es aceptable y simplifica el despliegue. En
produccion seria un `PersistentVolumeClaim`, y asi esta documentado.

## Metricas expuestas

| Metrica | Tipo | Golden Signal | Uso |
| --- | --- | --- | --- |
| `http_requests_total` | Counter | Trafico y Errores | Tasa de peticiones y de error por endpoint y codigo |
| `http_request_duration_seconds` | Histogram | Latencia | Percentiles p50, p95 y p99 |
| `app_inflight_requests` | Gauge | Saturacion | Peticiones concurrentes |
| `app_up` | Gauge | Disponibilidad | Senal de vida para `absent()` |
