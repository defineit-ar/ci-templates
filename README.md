# ci-templates

Reusable GitHub Actions workflows compartidos entre los proyectos de Define IT.
Público a propósito: no contiene secrets, solo la definición de los pipelines.
Cada repo que los usa pasa sus propios secrets al invocarlos.

Son **dos** workflows, y están separados a propósito:

| Workflow | Qué hace | Trigger típico en el repo llamador |
|---|---|---|
| `nextjs-checks.yml` | `lint` + `typecheck` en paralelo → `build` | `on: push` |
| `vercel-deploy-hook.yml` | Dispara un deploy en Vercel vía Deploy Hook | `on: workflow_dispatch` |

## Por qué están separados

Antes eran un solo workflow con el job de deploy colgado de los checks por
`needs`. El problema es que `needs` no cambia el trigger: si los checks corrían
al pushear, el deploy también. Y el objetivo era exactamente el contrario —
que el deploy lo dispare una persona y no un push.

Separados, cada repo elige el trigger de cada mitad: los checks al pushear, el
deploy cuando alguien aprieta el botón.

## Qué gatea el deploy (leer antes de asumir)

El gate es el **trigger del workflow llamador**, no algo dentro de estos
archivos. Invocando `vercel-deploy-hook.yml` desde un workflow con
`on: workflow_dispatch`, el deploy ocurre solo cuando una persona aprieta
"Run workflow".

Eso da **disparo manual**, que no es lo mismo que **aprobación de un segundo
par de ojos**: quien dispara puede ser quien escribió el código. La aprobación
real serían "Required reviewers" en un GitHub Environment, que en repos
privados requiere que el dueño de la cuenta/org tenga plan pago. Es una
limitación asumida.

El input `environment` sigue existiendo igual: registra el deploy en el
historial de deployments del repo, y el día que haya plan pago basta con
agregarle reviewers a ese Environment para que esto pase a ser aprobación real,
sin tocar los workflows.

## Uso

### `.github/workflows/ci.yml` — checks, sin deploy

```yaml
name: CI

on:
  push:
    branches: [main, staging]

jobs:
  checks:
    uses: defineit-ar/ci-templates/.github/workflows/nextjs-checks.yml@main
```

### `.github/workflows/deploy.yml` — deploy manual

```yaml
name: Deploy

on:
  workflow_dispatch:
    inputs:
      environment:
        description: "A dónde deployar"
        required: true
        type: choice
        options: [staging, production]

jobs:
  deploy:
    uses: defineit-ar/ci-templates/.github/workflows/vercel-deploy-hook.yml@main
    with:
      environment: ${{ inputs.environment }}
    secrets:
      deploy_hook_url: >-
        ${{ inputs.environment == 'production'
            && secrets.VERCEL_DEPLOY_HOOK_PRODUCTION
            || secrets.VERCEL_DEPLOY_HOOK_STAGING }}
```

> El botón "Run workflow" solo aparece cuando el archivo existe en el **branch
> por defecto** del repo. Hasta que `deploy.yml` no esté mergeado en `main`, el
> deploy no se puede disparar desde la UI, ni siquiera para `staging`.

## Setup requerido por repo llamador (una vez)

1. **Vercel** (necesita Owner/Developer en el proyecto):
   - Project Settings → Git → Deploy Hooks: crear uno por branch (`main`,
     `staging`).
   - **No usar "Ignored Build Step"** para desactivar el auto-deploy nativo:
     está documentado que si se configura en "Don't build anything" también
     bloquea los deploys disparados por Deploy Hook, no solo los de push
     automático. En su lugar, agregar un `vercel.json` en el repo del
     proyecto:
     ```json
     {
       "git": {
         "deploymentEnabled": {
           "main": false,
           "staging": false
         }
       }
     }
     ```
     Esto apaga el auto-deploy de git solo para esos branches sin afectar los
     Deploy Hooks, y no requiere permisos especiales en Vercel (es un archivo
     del repo). Nombrar solo esos branches deja intactos los previews que
     Vercel genera para los PRs.

     ⚠️ **Verificar esto en `staging` antes de aplicarlo a `main`.** Que
     `deploymentEnabled: false` no bloquee los Deploy Hooks está afirmado en
     los foros de Vercel, no probado por nosotros en cada proyecto. Si el
     supuesto estuviera mal, mergear las dos ramas a la vez deja al proyecto
     sin ningún camino de deploy: apagado el auto-deploy de git, y el hook
     tampoco dispara.

2. **GitHub, Secrets** (repo Settings → Secrets and variables → Actions):
   - `VERCEL_DEPLOY_HOOK_STAGING`
   - `VERCEL_DEPLOY_HOOK_PRODUCTION`

3. **GitHub, Environments** (repo Settings → Environments): opcional. Si el
   Environment no existe, GitHub lo crea solo al primer deploy. Agregarle
   "Required reviewers" es lo que convierte el disparo manual en aprobación
   real, y eso sí requiere plan pago en repos privados.

## Inputs

### `nextjs-checks.yml`

| Input | Default | Descripción |
|---|---|---|
| `working_directory` | `.` | Path a la app dentro del repo |
| `node_version` | `24` | Versión de Node. Conviene que coincida con la que usa Vercel para buildear el proyecto |
| `pnpm_version` | `9` | Versión de pnpm |

### `vercel-deploy-hook.yml`

| Input | Default | Descripción |
|---|---|---|
| `environment` | *(requerido)* | GitHub Environment donde se registra el deploy |

| Secret | Descripción |
|---|---|
| `deploy_hook_url` | URL del Vercel Deploy Hook para ese branch/environment |
