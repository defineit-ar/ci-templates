# ci-templates

Reusable GitHub Actions workflows compartidos entre los proyectos de Define IT.
Público a propósito: no contiene secrets, solo la definición del pipeline. Cada
repo que lo usa pasa sus propios secrets al invocarlo.

## nextjs-vercel-pipeline.yml

Pipeline para apps Next.js deployadas en Vercel, pensado para el caso en que
el deploy vía la integración nativa de Git de Vercel no es una opción para
todos los que pushean (por rol/seat). Reemplaza ese trigger por un
[Vercel Deploy Hook](https://vercel.com/docs/deployments/deploy-hooks),
que no depende de quién pushea.

Stages: `lint` + `typecheck` (paralelo) → `build` (gate: valida que compile
antes de gastar un deploy) → `deploy` (gateado por un GitHub Environment;
configurando "Required reviewers" en ese Environment el deploy queda manual).

### Uso

En el repo del proyecto, `.github/workflows/ci.yml`:

```yaml
name: CI/CD

on:
  push:
    branches: [main, staging]

jobs:
  staging:
    if: github.ref == 'refs/heads/staging'
    uses: defineit-ar/ci-templates/.github/workflows/nextjs-vercel-pipeline.yml@main
    with:
      environment: staging
    secrets:
      deploy_hook_url: ${{ secrets.VERCEL_DEPLOY_HOOK_STAGING }}

  production:
    if: github.ref == 'refs/heads/main'
    uses: defineit-ar/ci-templates/.github/workflows/nextjs-vercel-pipeline.yml@main
    with:
      environment: production
    secrets:
      deploy_hook_url: ${{ secrets.VERCEL_DEPLOY_HOOK_PRODUCTION }}
```

### Setup requerido por repo llamador (una vez)

1. **Vercel** (necesita permisos de Owner/Developer en el proyecto):
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
     Esto apaga el auto-deploy de git solo para esos branches sin afectar
     los Deploy Hooks, y no requiere permisos especiales en Vercel (es un
     archivo del repo).
2. **GitHub, Secrets** (repo Settings → Secrets and variables → Actions):
   - `VERCEL_DEPLOY_HOOK_STAGING`
   - `VERCEL_DEPLOY_HOOK_PRODUCTION`
3. **GitHub, Environments** (repo Settings → Environments; requiere admin del
   repo, y en repos privados un plan pago de GitHub para el dueño de la
   cuenta/org):
   - Crear `staging` y `production`.
   - Agregar "Required reviewers" en cada uno para que el job `deploy` quede
     pausado esperando aprobación manual.

### Inputs

| Input | Default | Descripción |
|---|---|---|
| `environment` | *(requerido)* | Nombre del GitHub Environment que gatea el deploy |
| `working_directory` | `.` | Path a la app dentro del repo |
| `node_version` | `22` | Versión de Node |
| `pnpm_version` | `9` | Versión de pnpm |

### Secrets

| Secret | Descripción |
|---|---|
| `deploy_hook_url` | URL del Vercel Deploy Hook para ese branch/environment |
