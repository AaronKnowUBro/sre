# Runbook de alertas

Cada alerta configurada en Prometheus tiene aqui su procedimiento de
atencion. El campo `runbook` de cada alerta apunta a la seccion
correspondiente de este documento.

Una alerta sin runbook obliga a quien esta de guardia a improvisar a las tres
de la madrugada. Por eso toda alerta nueva debe documentarse aqui antes de
entrar al repositorio.

## Indice

- [HighErrorRate](#higherrorrate)
- [HighLatencyP95](#highlatencyp95)
- [HighSaturation](#highsaturation)
- [NoTraffic](#notraffic)
- [AppInstanceDown](#appinstancedown)
- [AppMetricsMissing](#appmetricsmissing)

---

## HighErrorRate

| Campo | Valor |
| --- | --- |
| Severidad | `critical` |
| Umbral | mas del 20% de respuestas 5xx |
| Ventana | `for: 1m` |

**Que significa.** Mas de una de cada cinco peticiones esta fallando. El
impacto al usuario es inmediato y visible.

**Como diagnosticar.**

```bash
# 1. Que endpoint concentra los errores
# En Prometheus:
sum(rate(http_requests_total{status=~"5.."}[5m])) by (endpoint)

# 2. Revisar los logs de la aplicacion
kubectl logs -n sre-app -l app=sre-app --tail=100

# 3. Confirmar que los pods no esten reiniciando
kubectl get pods -n sre-app
```

**Causas probables.**

1. `ERROR_RATE` quedo configurado alto en el Deployment (causa esperada
   durante las demostraciones).
2. Una dependencia externa de la aplicacion esta caida.
3. Un despliegue reciente introdujo un error.

**Mitigacion.**

```bash
# Bajar la tasa de error simulada
kubectl set env -n sre-app deployment/sre-app ERROR_RATE=0.01

# Si el problema vino de un despliegue, revertir
kubectl rollout undo -n sre-app deployment/sre-app
```

---

## HighLatencyP95

| Campo | Valor |
| --- | --- |
| Severidad | `warning` |
| Umbral | p95 mayor a 1 segundo |
| Ventana | `for: 2m` |

**Que significa.** El 5% de las peticiones mas lentas tarda mas de un
segundo. Se usa p95 y no el promedio porque el promedio esconde la cola
lenta, que es justo la que molesta al usuario.

**Como diagnosticar.**

```bash
# Latencia por endpoint
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, endpoint))

# Descartar falta de CPU
kubectl top pods -n sre-app
```

**Causas probables.**

1. Trafico dirigido a `/slow` (causa esperada en las demostraciones).
2. CPU insuficiente: el pod esta siendo limitado por su `limit`.
3. `MAX_LATENCY` configurado demasiado alto.

**Mitigacion.**

```bash
# Dar mas CPU
kubectl set resources -n sre-app deployment/sre-app --limits=cpu=600m

# Escalar horizontalmente
kubectl scale -n sre-app deployment/sre-app --replicas=4
```

---

## HighSaturation

| Campo | Valor |
| --- | --- |
| Severidad | `warning` |
| Umbral | mas de 20 peticiones en curso |
| Ventana | `for: 2m` |

**Que significa.** Se estan acumulando peticiones sin terminar. Es una senal
temprana: si no se atiende, se convierte en latencia alta y despues en
errores por timeout.

**Como diagnosticar.**

```bash
sum(app_inflight_requests) by (kubernetes_pod_name)
kubectl top pods -n sre-app
```

**Mitigacion.** Escalar replicas o aumentar los workers de Gunicorn en el
`CMD` del Dockerfile.

---

## NoTraffic

| Campo | Valor |
| --- | --- |
| Severidad | `info` |
| Umbral | 0 peticiones por segundo |
| Ventana | `for: 5m` |

**Que significa.** Nadie esta llamando a la aplicacion. Puede ser normal en
un entorno de practica, o indicar que algo aguas arriba dejo de enviar
trafico.

**Mitigacion.** Si se espera trafico, generarlo:

```bash
./scripts/load-test.sh normal 300
```

---

## AppInstanceDown

| Campo | Valor |
| --- | --- |
| Severidad | `critical` |
| Umbral | `up == 0` |
| Ventana | `for: 1m` |

**Que significa.** Prometheus no logra recolectar metricas de un pod
especifico. El pod puede estar caido, reiniciandose o con la red bloqueada.

**Como diagnosticar.**

```bash
kubectl get pods -n sre-app -o wide
kubectl describe pod -n sre-app <nombre-del-pod>
kubectl logs -n sre-app <nombre-del-pod> --previous
```

**Causas probables.**

1. CrashLoopBackOff por un error en el arranque de la aplicacion.
2. OOMKilled: el pod excedio su limite de memoria.
3. La probe de readiness falla y el pod salio del Service.

**Mitigacion.**

```bash
kubectl rollout restart -n sre-app deployment/sre-app
# Si fue OOMKilled:
kubectl set resources -n sre-app deployment/sre-app --limits=memory=512Mi
```

---

## AppMetricsMissing

| Campo | Valor |
| --- | --- |
| Severidad | `critical` |
| Umbral | `absent(app_up)` |
| Ventana | `for: 2m` |

**Que significa.** La metrica desaparecio por completo: ningun pod esta
siendo recolectado. Es distinto de `AppInstanceDown`, que detecta un pod que
existe pero no responde. Esta alerta cubre el caso en que el target ya ni
aparece en el service discovery.

**Como diagnosticar.**

```bash
# 1. Revisar los targets en Prometheus
#    http://localhost:9090/targets  -> buscar el job kubernetes-pods

# 2. Verificar que las anotaciones del pod sigan en su lugar
kubectl get pods -n sre-app -o jsonpath='{.items[*].metadata.annotations}'

# 3. Confirmar que el RBAC siga funcionando
kubectl logs -n monitoring deploy/prometheus | grep -i forbidden
```

**Causas probables.**

1. Se borraron las anotaciones `prometheus.io/scrape` del Deployment.
2. El ClusterRoleBinding de Prometheus fue eliminado y el discovery da 403.
3. El namespace completo fue eliminado.

**Mitigacion.**

```bash
kubectl apply -f k8s/20-prometheus-rbac.yaml
kubectl apply -f k8s/10-app.yaml
kubectl rollout restart -n monitoring deployment/prometheus
```
