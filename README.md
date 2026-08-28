# ci-templates

Reusable GitHub Actions workflows compartidos entre los proyectos de Define IT.
Público a propósito: no contiene secrets, solo la definición de los pipelines.
Cada repo que los usa pasa sus propios secrets al invocarlos.

Son **dos** workflows, y están separados a propósito:

| Workflow | Qué hace | Trigger típico en el repo llamador |
|---|---|---|
| `nextjs-checks.yml` | `lint` + `typecheck` en paralelo → `build` | `on: push` |
| `vercel-cli-deploy.yml` | Deploya a Vercel por CLI, autenticado con un token | `on: workflow_dispatch` |

## Por qué están separados

Antes eran un solo workflow con el job de deploy colgado de los checks por
`needs`. El problema es que `needs` no cambia el trigger: si los checks corrían
al pushear, el deploy también. Y el objetivo era exactamente el contrario —
que el deploy lo dispare una persona y no un push.

Separados, cada repo elige el trigger de cada mitad: los checks al pushear, el
deploy cuando alguien aprieta el botón.

## Por qué CLI + token y no un Deploy Hook

La primera versión de `vercel-cli-deploy.yml` era un Deploy Hook (un
`curl -X POST` a la URL que genera Vercel). Se descartó: un Deploy Hook sigue
creando un deployment con `source: git`, atado al commit HEAD de la rama en
ese momento. Vercel resuelve el permiso de deployar contra el **rol del autor
de ese commit** en el team, no contra quién (o qué) llamó al hook.

Verificado en `my-turn` el 2026-08-28: el hook de staging respondió HTTP 201
(aceptado), pero el deployment resultante quedó en `BLOCKED` — cero build
logs, con `errorLink` al doc de troubleshooting de "team-configuration" de
Vercel. El commit en HEAD de staging en ese momento era de un miembro con rol
Viewer en el team, y el deploy se bloqueó por eso. Exactamente lo que el
mecanismo se suponía que iba a esquivar.

`vercel deploy --prebuilt` en cambio sube archivos directamente (`source:
cli`, sin `gitSource`): no hay commit-author que resolver. El permiso lo
define el **Personal Access Token**: si pertenece a una cuenta con rol
suficiente en el team (Owner/Developer), el deploy sale sin importar quién
mergeó el último commit.

## Qué gatea el deploy (leer antes de asumir)

El gate sigue siendo el **trigger del workflow llamador**, no algo dentro de
estos archivos. Invocando `vercel-cli-deploy.yml` desde un workflow con
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

## Sin verificar todavía

La secuencia `pull → build → deploy --prebuilt` es la que documenta Vercel
para CI/CD, y `--target=<nombre>` para custom environments (como `staging`,
que no es el `preview` por defecto de Vercel) también es de la doc oficial —
pero la combinación de las dos cosas no se probó de punta a punta contra un
deployment real todavía (bloqueado en conseguir un token). Si el primer run
falla, empezar mirando si `vercel build` necesita su propio flag de
environment además de heredarlo de `vercel pull` — no encontré uno
documentado, pero puede que exista.

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
    uses: defineit-ar/ci-templates/.github/workflows/vercel-cli-deploy.yml@main
    with:
      environment: ${{ inputs.environment }}
      vercel_org_id: team_SE6AEXkckvqVzIwFnJX3wl4r
      vercel_project_id: prj_BvmltctGEUS2otUb1ik4R0upq2EA
    secrets:
      vercel_token: ${{ secrets.VERCEL_TOKEN }}
```

> El botón "Run workflow" solo aparece cuando el archivo existe en el **branch
> por defecto** del repo. Hasta que `deploy.yml` no esté mergeado en `main`, el
> deploy no se puede disparar desde la UI, ni siquiera para `staging`.
>
> `vercel_org_id` / `vercel_project_id` no son secretos (están en la URL del
> dashboard de Vercel y en cualquier `.vercel/project.json`), así que van como
> `with:`, no como `secrets:`.

## Setup requerido por repo llamador (una vez)

1. **Vercel**: generar un Personal Access Token, scopeado al proyecto (no a
   toda la cuenta), desde una cuenta con rol Owner/Developer en el team:
   ```bash
   vercel tokens add "nombre-descriptivo" --project prj_XXXXXXXXXXXXXXXXXXXXXXXX
   ```
   Imprime el token una sola vez.

2. **GitHub, Secrets** (repo Settings → Secrets and variables → Actions):
   ```bash
   gh secret set VERCEL_TOKEN --repo <owner>/<repo> --body "<el token>"
   ```

3. **`vercel.json`** del proyecto — apagar el auto-deploy de git para que no
   compita con el deploy manual, sin usar "Ignored Build Step" (documentado
   que también bloquea los deploys por CLI/hook, no solo los de push
   automático):
   ```json
   {
     "$schema": "https://openapi.vercel.sh/vercel.json",
     "git": {
       "deploymentEnabled": {
         "main": false,
         "staging": false
       }
     }
   }
   ```
   Nombrar solo esos branches deja intactos los previews que Vercel genera
   para los PRs.

4. **GitHub, Environments** (repo Settings → Environments): opcional. Si el
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

### `vercel-cli-deploy.yml`

| Input | Default | Descripción |
|---|---|---|
| `environment` | *(requerido)* | Target de Vercel (`production` o un custom environment como `staging`) y GitHub Environment donde se registra el deploy |
| `working_directory` | `.` | Path a la app dentro del repo |
| `vercel_org_id` | *(requerido)* | Team/org ID de Vercel (no es secreto) |
| `vercel_project_id` | *(requerido)* | Project ID de Vercel (no es secreto) |
| `vercel_cli_version` | `latest` | Versión del paquete `vercel` |

| Secret | Descripción |
|---|---|
| `vercel_token` | Personal Access Token de Vercel, scopeado al proyecto |
