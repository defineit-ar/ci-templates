# Política de CI de Define IT

Reglas para escribir y usar workflows de GitHub Actions en la org `defineit-ar`
(y repos personales que corren en Ubicloud). Valen para personas y para agentes.

## Por qué existe

Todo el CI corre en Ubicloud (`ubicloud-standard-2`, USD 0,002/min). Los agentes
Claude hacen más de 100 commits por día, y el CI está pensado como si cada commit
fuera un candidato a merge. Medido entre 2026-10-12 y 2026-10-19:

- Minutos de runner: define-dwh 4076, Emissa 529, agents-runtime 308, inmos-api 286,
  camilo-liotta/control-plane 197.
- **El 78% del total es un solo workflow: `dbt CI` de define-dwh**: 2708 jobs en una
  semana, 2554 de ellos de menos de 60 s. Suman 2307 minutos reales pero se cobran
  3624, porque Ubicloud **redondea al minuto por job**. Cada job además paga el
  arranque de una VM y ~18 s de cola.
- define-dwh tuvo 139 corridas de `pull_request` en 57 ramas y 63 de `push` a main.

El costo no está en lo que corre cada check, sino en **cuántas veces** y **en cuántos
jobs** se parte. Las reglas atacan eso, y también el tiempo que se espera al CI.

---

## R1. La unidad de verificación es el PR listo, no el commit

Los agentes abren PRs en **draft** mientras trabajan. Los jobs de CI de PR corren sólo
si el PR no es draft. Los pushes a ramas sin PR no disparan nada: `push` sólo en la
rama por defecto.

**Por qué:** un commit intermedio de un agente no es un candidato a merge; verificarlo
es pagar por información que nadie va a usar. Un PR en draft declara "todavía no".

```yaml
on:
  pull_request:
    types: [opened, reopened, synchronize, ready_for_review, converted_to_draft]
  push:
    branches: [main]          # sólo la rama por defecto

jobs:
  checks:
    if: github.event_name != 'pull_request' || !github.event.pull_request.draft
    runs-on: ubicloud-standard-2
```

`ready_for_review` es imprescindible: por defecto `pull_request` no lo escucha, y sin
él, pasar un draft a listo no dispararía nada. `converted_to_draft` hace que
`gh pr ready --undo` (R7) **cancele la corrida en curso**: llega una corrida nueva cuyos
jobs salen todos `skipped` y, al compartir el grupo de `concurrency` (R2), cancela a la
anterior; sin él, el PR vuelve a draft y la corrida vieja sigue facturando hasta
terminar. (Verificado en define-dwh#231.)

La condición se escribe `github.event_name != 'pull_request' || !github.event.pull_request.draft`
y no `draft == false`: en `push` y `schedule` no hay `pull_request`, y esta forma dice sin
ambigüedad que ahí el job corre. Si el job también tiene que ser de `closed` (limpieza),
agregar `closed` a `types` y no filtrar ese job por draft: un PR puede pasar a draft
después de haber corrido.

## R2. Cancelar lo obsoleto

Todo workflow de PR lleva `concurrency` con un grupo por workflow y PR y
`cancel-in-progress: true`. En main **no** se cancelan deploys.

**Por qué:** si el agente pushea de nuevo, la corrida anterior ya no sirve y sigue
facturando hasta terminar.

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}   # main: nunca
```

**Trampa: `always()` anula `cancel-in-progress`.** `always()` es verdadero también cuando
la corrida se canceló, así que un job con `needs` e `if: always() && ...` que todavía no
había arrancado **arranca igual** después de la cancelación y corre hasta el final. Se
cancela el primer job y los pesados siguen facturando (medido en Emissa#150: arrancaron ~1
min después de cancelar; en ese repo la cancelación nunca había cortado los jobs pesados).
Regla: **los jobs de trabajo usan `if: ${{ !cancelled() && ... }}`** (corre si una
dependencia falló o se salteó, pero no si se canceló la corrida), con `${{ }}` porque un
`!` suelto al inicio del valor es un tag de YAML y el archivo no parsea. **Sólo el agregador
`ci-ok` usa `always()`** (R4): es el único que tiene que reportar aun con la corrida
cancelada. Con `always()` en un job de trabajo, la salida de emergencia es
`gh api -X POST repos/<org>/<repo>/actions/runs/<id>/force-cancel`.

## R3. No fragmentar

Los checks que duran menos de ~2 min van como **steps de un mismo job**, no como jobs
separados. Un job aparte sólo si dura más de ~3 min **y** gana algo real corriendo en
paralelo, o si necesita otro runner o permisos.

**Por qué:** se cobra el minuto redondeado **por job**, y cada job arranca una VM y
espera cola. Tres checks de 20 s en tres jobs son 3 minutos facturados y ~1 min de
espera; en un solo job son 1 minuto y ~20 s de espera.

Si hace falta ver cada check por separado, se usan steps con nombre y
`$GITHUB_STEP_SUMMARY`, o un job agregador (ver R4).

```yaml
jobs:
  checks:
    runs-on: ubicloud-standard-2
    steps:
      - uses: actions/checkout@v4
      - run: pnpm install --frozen-lockfile
      - name: Lint
        run: pnpm lint
      - name: Typecheck
        run: pnpm exec tsc --noEmit
      - name: Tests
        run: pnpm test
      - if: always()
        run: echo "### Checks terminados" >> "$GITHUB_STEP_SUMMARY"
```

## R4. Correr sólo lo afectado

Filtros de `paths` **por job** (por ejemplo con `dorny/paths-filter`), para que un
cambio de docs o de un área no corra todo. Si hay checks requeridos, un job agregador
`ci-ok`, siempre presente, que sea el único required. **No usar `paths` a nivel de
workflow con checks requeridos.**

**Un solo job de verificación: sin `changes` ni `ci-ok`.** Cada uno es otro job y otro
minuto facturado, así que no se justifican. El filtro va como **primer step** del job
(`dorny/paths-filter` o un `git diff --name-only`) y el resto de los steps lleva
`if: steps.f.outputs.app == 'true'`. Con un solo job, su propio nombre es el check.

**Plan free y repos privados: `ci-ok` es convención, no un bloqueo.** En el plan free de
GitHub los repos privados no tienen required checks, branch protection ni rulesets (la API
responde 403 "Upgrade to GitHub Pro or make this repository public"; es el caso de la
org `defineit-ar`). Nada impide mergear con el CI rojo: lo que impide es la regla para
agentes y personas (no mergear sin el CI del último commit en verde, `gh pr checks`).
`ci-ok` sigue sirviendo como una sola señal que mirar, y queda listo para el día en que
el plan cambie.

**Por qué:** con `paths:` a nivel workflow, si no hay coincidencia el workflow no corre
y los checks requeridos quedan en "Expected" para siempre: el PR no se puede mergear.
Con filtros por job, el workflow siempre corre y `ci-ok` siempre reporta.

```yaml
jobs:
  changes:
    if: github.event.pull_request.draft == false
    runs-on: ubicloud-standard-2
    permissions: { contents: read, pull-requests: read }
    outputs:
      app: ${{ steps.f.outputs.app }}
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: f
        with:
          filters: |
            app: ['src/**', 'package.json', 'pnpm-lock.yaml']

  checks:
    needs: changes
    if: needs.changes.outputs.app == 'true'
    # ...

  ci-ok:
    if: always() && github.event.pull_request.draft == false
    needs: [changes, checks]
    runs-on: ubicloud-standard-2
    steps:
      - env: { RESULTS: "${{ join(needs.*.result, ' ') }}" }
        run: |
          case " $RESULTS " in *" failure "*|*" cancelled "*) exit 1 ;; esac
```

Dos trampas: `ci-ok` **necesita `always()`** (si no, cuando un job falla `ci-ok` se
saltea, y un check salteado cuenta como aprobado) y debe fallar explícitamente ante
`failure`/`cancelled`. Y tanto `changes` como `ci-ok` son jobs, o sea una VM y 1 minuto
facturado cada uno (R3): en un repo con un solo job de verificación, hacer el filtro
como primer step de ese job y no usar `ci-ok`.

Referencia completa y copiable: [`examples/pr-ci.yml`](examples/pr-ci.yml).

## R5. No repetir sobre main lo que ya pasó en el PR

En push a main corre sólo lo que el PR no puede garantizar: deploy, smoke,
migraciones. Se acepta el riesgo del squash/merge. La suite completa corre por
`schedule` una vez por día.

**Excepción válida: main es la única corrida que prueba el árbol combinado.** Sin merge
queue ni "require branches up to date" (en el plan free no existen), dos PR verdes por
separado pueden mergear limpio y romperse juntos: ningún PR probó el árbol resultante.
Si el repo decidió que esa corrida es la que lo atrapa, **se corre la suite completa en
main, sin filtros de paths ni saltos, y se documenta en el workflow** (define-dwh lo hace
y dice por qué en la cabecera de `ci.yml`). Un filtro de paths en main sería peor que
costoso: un merge solo de docs sobre un main en rojo saldría verde y taparía el rojo. El
ahorro se busca en lo demás (R3, R4 en PRs). Es una decisión explícita del repo, no un
default; sin esa razón documentada, vale la regla general.

**Por qué:** repetir lint, tests y build sobre el mismo árbol que ya pasó en el PR
duplica el costo sin información nueva. El riesgo residual (un merge que combina mal
dos PRs) lo atrapa la corrida diaria.

Límite del `schedule`: corre sólo en la rama por defecto y GitHub **lo desactiva tras 60
días sin actividad** en el repo, sin aviso. En un repo con poca actividad ese colchón
diario puede apagarse solo; si importa, que alguien lo vea (un commit o reactivarlo a
mano alcanza).

```yaml
on:
  push:
    branches: [main]
  schedule:
    - cron: "0 7 * * *"        # suite completa, una vez por día

jobs:
  full-suite:
    if: github.event_name == 'schedule'
    # ...
  deploy:
    if: github.event_name == 'push'
    # ...
```

## R6. Rápido y acotado

`timeout-minutes` en todo job; cache de dependencias (`setup-node`/`setup-python` con
`cache:`, que en Ubicloud se vuelve transparente); `ubicloud-standard-2` por defecto.

**Por qué:** un job colgado factura hasta el timeout por defecto de 6 horas. Sin cache
cada corrida reinstala todo. Subir de tamaño de runner sólo si se mide que paga.

```yaml
jobs:
  checks:
    runs-on: ubicloud-standard-2
    timeout-minutes: 15
    steps:
      - uses: actions/setup-node@v4
        with: { node-version: 24, cache: pnpm }
```

## R7. Antes de pedir CI, verifica el agente

El agente corre localmente lint, typecheck y los tests del área tocada. Hace commits
libremente, pero **pushea en tandas** y marca el PR `ready` sólo cuando es un
candidato. Para corregir un PR ya listo con varias iteraciones, lo vuelve a draft
(`gh pr ready --undo`) y lo marca listo al final.

**Por qué:** el CI es la última verificación, no el ciclo de edición. Cada ida y vuelta
al CI cuesta minutos de espera además de plata.

```bash
gh pr create --draft --fill          # trabajar en draft
# ... commits, pushes en tandas, verificación local ...
gh pr ready                          # sólo cuando es un candidato a merge
gh pr ready --undo                   # si hay que iterar sobre un PR ya listo
```

La versión corta, en imperativo, para `CLAUDE.md` de los agentes, está en la sección
`## CI y PRs` de `~/.claude/CLAUDE.md`.

## R8. Medir

Cuatro métricas, revisadas semanalmente:

| Métrica | Cómo se lee | Objetivo |
|---|---|---|
| Minutos facturados por PR mergeado | minutos de runner (redondeados por job) ÷ PRs mergeados | bajar |
| Jobs de menos de 60 s | cantidad en la semana | tender a 0 (R3) |
| Corridas canceladas | `conclusion == cancelled` | suben al aplicar R2 y es buena señal |
| Regresiones en main | corridas rojas en main que el PR había dejado verdes | ~0 (si suben, R5 cuesta demasiado) |

Las cuatro se sacan de una sola corrida de [`scripts/ci-costo.sh`](scripts/ci-costo.sh)
(bash + `gh` + `jq`, sin dependencias nuevas):

```bash
scripts/ci-costo.sh defineit-ar                 # org, últimos 7 días, repos no archivados con push
scripts/ci-costo.sh defineit-ar 14 Emissa inmos-api   # 14 días, solo esos repos
scripts/ci-costo.sh --json camilo-liotta 30     # JSON, para guardar o graficar
```

Por repo y workflow muestra corridas (y por evento), jobs, jobs de menos de 60 s, minutos
reales y facturados (`ceil(dur/60)` por job, sin los salteados) y corridas canceladas; por
repo, corridas por PR y minutos por PR mergeado; y un total. Los minutos de `ubicloud-*`
van separados de los de runners de GitHub, y los repos públicos se marcan `[pub]`: sus
minutos de GitHub son gratis. Pide un run una sola vez, pero cuesta una llamada a la API
por corrida (una org con ~500 corridas por semana tarda unos 5 minutos). Hace falta `gh`
autenticado con acceso de lectura a Actions.

Una corrida concreta, para mirar a mano:

```bash
# jobs de una corrida con su duración
gh run view <run-id> --json jobs \
  --jq '.jobs[] | {name, s: ((.completedAt|fromdate) - (.startedAt|fromdate))}'
```

---

## Checklist para revisar un workflow

1. ¿`pull_request` incluye `ready_for_review` y `converted_to_draft`, y los jobs filtran `!github.event.pull_request.draft`?
2. ¿`push` sólo en la rama por defecto?
3. ¿Hay `concurrency` con `cancel-in-progress` en PRs (y no en main)?
4. ¿Hay jobs de < 2 min que podrían ser steps de otro job?
5. ¿Cada job tiene `timeout-minutes`?
6. ¿Hay cache de dependencias (`cache:` en setup-*)?
7. ¿Un cambio de docs o de otra área corre todo? ¿Usa `paths` por job, no por workflow?
8. Con varios jobs: ¿hay un único `ci-ok` con `always()`? (Con uno solo, no.)
9. ¿En push a main sólo corre lo que el PR no garantiza?
10. ¿La suite completa tiene `schedule` diario y `runs-on: ubicloud-standard-2`?
11. ¿Ningún job de trabajo con `always()`? Usan `${{ !cancelled() && ... }}`; `always()` sólo en `ci-ok`.
