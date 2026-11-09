# Guia de contribucion

Gracias por tu interes en este proyecto. Aqui encontraras como proponer
cambios, que convenciones seguimos y como validar tu trabajo antes de abrir
un Pull Request.

## Tabla de contenidos

- [Codigo de conducta](#codigo-de-conducta)
- [Como reportar un problema](#como-reportar-un-problema)
- [Entorno de desarrollo](#entorno-de-desarrollo)
- [Flujo de trabajo con Git](#flujo-de-trabajo-con-git)
- [Convencion de commits](#convencion-de-commits)
- [Estandares de codigo](#estandares-de-codigo)
- [Validacion antes del Pull Request](#validacion-antes-del-pull-request)
- [Proceso de revision](#proceso-de-revision)

## Codigo de conducta

Se espera respeto y profesionalismo en issues, Pull Requests y revisiones.
Las discusiones se centran en el codigo y las decisiones tecnicas, nunca en
las personas. El acoso o lenguaje despectivo no se tolera.

## Como reportar un problema

Abre un issue con:

1. **Que esperabas** que ocurriera.
2. **Que ocurrio** en realidad.
3. **Pasos para reproducirlo**, incluyendo comandos exactos.
4. **Entorno**: version de Minikube, `kubectl version`, sistema operativo.
5. **Evidencia**: salida de `kubectl logs`, `kubectl describe` o screenshots.

## Entorno de desarrollo

Requisitos previos:

| Herramienta | Version minima |
| ----------- | -------------- |
| Docker      | 24.x           |
| Minikube    | 1.33           |
| kubectl     | 1.30           |
| Python      | 3.12           |
| Helm        | 3.15 (opcional) |

Para levantar el entorno completo:

```bash
./scripts/cluster.sh
```

Para trabajar solo en la aplicacion, sin Kubernetes:

```bash
cd app
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python app.py
# La app queda en http://localhost:5000 y las metricas en /metrics
```

## Flujo de trabajo con Git

Usamos ramas de funcionalidad sobre `main`. Nunca se hace commit directo a
`main`.

```bash
git checkout main
git pull origin main
git checkout -b feat/nombre-descriptivo
# ... cambios ...
git push -u origin feat/nombre-descriptivo
```

Prefijos de rama:

- `feat/` funcionalidad nueva
- `fix/` correccion de un error
- `docs/` solo documentacion
- `refactor/` reorganizacion sin cambio de comportamiento
- `chore/` mantenimiento, dependencias, CI

## Convencion de commits

Seguimos [Conventional Commits](https://www.conventionalcommits.org/):

```
<tipo>(<alcance opcional>): <descripcion en imperativo>
```

Ejemplos reales de este repositorio:

```
feat(app): agregar gauge de peticiones en curso
fix(prometheus): corregir relabel del puerto en el service discovery
docs(readme): documentar los umbrales de las alertas
chore(ci): validar manifests con kubeconform
```

## Estandares de codigo

**Python**

- Se sigue PEP 8, con lineas de maximo 88 caracteres.
- Cada funcion lleva docstring explicando su proposito.
- Las metricas nuevas usan labels de cardinalidad baja: nunca IDs de usuario,
  UUIDs ni rutas con parametros variables, porque cada valor distinto crea una
  serie temporal nueva y degrada a Prometheus.

**YAML de Kubernetes**

- Indentacion de 2 espacios.
- Todo recurso declara `requests` y `limits`.
- Los archivos van numerados por orden de aplicacion (`00-`, `10-`, `20-`...).
- Los comentarios explican **por que** se tomo una decision, no que hace la
  linea.

**Alertas de Prometheus**

Toda alerta nueva debe incluir:

- `for:` con una duracion, para evitar alertas por un pico momentaneo.
- `severity:` en labels (`critical`, `warning` o `info`).
- `summary` y `description` en annotations.
- Una entrada correspondiente en [`docs/runbook.md`](docs/runbook.md).

Una alerta sin runbook es una alerta que nadie sabe atender.

## Validacion antes del Pull Request

```bash
# Sintaxis de Python
python -m py_compile app/app.py

# Sintaxis de los manifests
kubectl apply --dry-run=client -f k8s/

# Reglas de alerta
docker run --rm -v "$PWD/k8s:/k8s" --entrypoint promtool \
  prom/prometheus:v2.54.1 check config /k8s/21-prometheus.yaml

# Chart de Helm
helm lint helm/sre-app
```

El pipeline de GitHub Actions ejecuta estas mismas validaciones en cada push.

## Proceso de revision

1. Abre el Pull Request contra `main` describiendo el **por que** del cambio.
2. Espera que el pipeline de CI pase en verde.
3. Si el cambio afecta dashboards o alertas, adjunta un screenshot.
4. Atiende los comentarios con commits nuevos, sin reescribir la historia
   mientras la revision este abierta.
