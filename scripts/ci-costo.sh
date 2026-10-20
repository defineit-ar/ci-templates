#!/usr/bin/env bash
# ci-costo.sh: mide el costo del CI de GitHub Actions (R8 de POLITICA-CI.md).
#
# Uso: scripts/ci-costo.sh [--json] OWNER [DIAS] [REPO...]
#   OWNER  org o usuario (defineit-ar, camilo-liotta)
#   DIAS   ventana hacia atrás desde ahora (por defecto 7)
#   REPO   uno o más repos del OWNER; sin ellos, todos los no archivados con push en la ventana
#   --json salida JSON en vez de tabla
#
# Requiere gh (autenticado, con acceso de lectura a Actions de los repos) y jq. GNU date.
#
# Reglas de cálculo:
#   - Minutos facturados = suma de ceil(duración/60) por job, sin contar los jobs salteados
#     (ni los que no llegaron a empezar). Minutos reales = suma de duraciones / 60.
#   - Un job es de Ubicloud si alguna de sus labels empieza con `ubicloud`; el resto se cuenta
#     como runner de GitHub. Los minutos de runners de GitHub de un repo público son gratis
#     (se marcan con "pub"); Ubicloud se cobra igual.
#   - "Corridas por PR" = corridas de `pull_request` / PRs distintos que las dispararon.
#     "min/PR mergeado" = minutos facturados del repo (ambos tipos de runner) / PRs
#     mergeados en la ventana (0 PRs mergeados => "-").
#   - Cada run se pide una sola vez (se deduplica por id) y todo se pagina.
set -euo pipefail

JSON=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *) ARGS+=("$a") ;;
  esac
done
[ "${#ARGS[@]}" -ge 1 ] || { echo "uso: $0 [--json] OWNER [DIAS] [REPO...]" >&2; exit 2; }
OWNER=${ARGS[0]}
DAYS=7
REPOS=()
if [ "${#ARGS[@]}" -ge 2 ]; then
  if [[ ${ARGS[1]} =~ ^[0-9]+$ ]]; then DAYS=${ARGS[1]}; REPOS=("${ARGS[@]:2}"); else REPOS=("${ARGS[@]:1}"); fi
fi
command -v gh >/dev/null && command -v jq >/dev/null || { echo "faltan gh y jq" >&2; exit 2; }

SINCE=$(date -u -d "$DAYS days ago" +%Y-%m-%dT%H:%M:%SZ)
SINCE_DAY=${SINCE%%T*}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Repos: nombre, visibilidad. Sin lista explícita, solo los no archivados con push en la ventana.
gh repo list "$OWNER" --limit 500 --json name,isArchived,isPrivate,pushedAt >"$TMP/repos.json"
if [ "${#REPOS[@]}" -eq 0 ]; then
  jq -r --arg s "$SINCE" '.[]|select((.isArchived|not) and .pushedAt>=$s)|.name' "$TMP/repos.json" | sort >"$TMP/names"
else
  printf '%s\n' "${REPOS[@]}" >"$TMP/names"
fi

# Trae runs y jobs de un repo a $TMP/<repo>.{runs,jobs,merged}
fetch_repo() {
  local repo=$1 out=$2/$1
  gh api --paginate -X GET "repos/$OWNER/$repo/actions/runs" -f per_page=100 -f "created=>=$SINCE" \
    --jq '.workflow_runs[]|{id,name,event,conclusion,pr:(.pull_requests[0].number // .head_branch)}' 2>/dev/null |
    jq -s -c 'unique_by(.id)|.[]' >"$out.runs" || : >"$out.runs"
  : >"$out.jobs.raw"
  while read -r id; do
    gh api --paginate "repos/$OWNER/$repo/actions/runs/$id/jobs?per_page=100" \
      --jq ".jobs[]|{id,run:$id,conclusion,labels,s:.started_at,c:.completed_at}" >>"$out.jobs.raw" 2>/dev/null || true
  done < <(jq -r .id "$out.runs")
  jq -s -c 'unique_by(.id)|.[]' "$out.jobs.raw" >"$out.jobs"
  gh pr list -R "$OWNER/$repo" --state merged --search "merged:>=$SINCE_DAY" --limit 1000 \
    --json number --jq length >"$out.merged" 2>/dev/null || echo 0 >"$out.merged"
}
export -f fetch_repo
export OWNER SINCE SINCE_DAY
xargs -a "$TMP/names" -P 6 -I{} bash -c 'fetch_repo "$1" "$2"' _ {} "$TMP"

# Agregación por repo
while read -r repo; do
  pub=$(jq -r --arg r "$repo" '.[]|select(.name==$r)|(.isPrivate|not)' "$TMP/repos.json")
  jq -n --arg repo "$repo" --argjson pub "${pub:-false}" --argjson merged "$(cat "$TMP/$repo.merged")" \
    --slurpfile runs "$TMP/$repo.runs" --slurpfile jobs "$TMP/$repo.jobs" '
    def sinf: select(.conclusion != "skipped" and .s != null and .c != null
                     and (.s|startswith("0001")|not) and (.c|startswith("0001")|not));
    ($runs|map({key:(.id|tostring),value:.name})|from_entries) as $wf
    | ($jobs|map(sinf|. + {d:((.c|fromdate)-(.s|fromdate)), wf:$wf[(.run|tostring)],
                          ubi:(any(.labels[]?; startswith("ubicloud")))})) as $j
    | def mins(f): ($j|map(select(f)|(.d/60|ceil))|add // 0);
      {repo:$repo, public:$pub,
       workflows: ($runs|group_by(.name)|map(. as $rs | .[0].name as $n | ($j|map(select(.wf==$n))) as $jw | {
          workflow:$n, runs:length,
          events:(group_by(.event)|map({(.[0].event):length})|add),
          cancelled_runs:(map(select(.conclusion=="cancelled"))|length),
          jobs:($jw|length), jobs_lt60:($jw|map(select(.d<60))|length),
          real_min:(($jw|map(.d)|add // 0)/60*10|round/10),
          billed_ubicloud:($jw|map(select(.ubi)|(.d/60|ceil))|add // 0),
          billed_github:($jw|map(select(.ubi|not)|(.d/60|ceil))|add // 0)}))|sort_by(-(.billed_ubicloud+.billed_github)),
       prs:($runs|map(select(.event=="pull_request")|.pr)|unique|length),
       pr_runs:($runs|map(select(.event=="pull_request"))|length),
       merged_prs:$merged}
    | . + {billed_total:(.workflows|map(.billed_ubicloud+.billed_github)|add // 0)}
    | . + {runs_per_pr:(if .prs>0 then (.pr_runs/.prs*10|round/10) else null end),
           min_per_merged_pr:(if .merged_prs>0 then (.billed_total/.merged_prs*10|round/10) else null end)}' \
    >"$TMP/$repo.agg"
done <"$TMP/names"

jq -s --arg owner "$OWNER" --arg since "$SINCE" --argjson days "$DAYS" '
  map(select(.workflows|length>0)) as $r
  | {owner:$owner, since:$since, days:$days, repos:$r,
     total:{runs:($r|map(.workflows|map(.runs)|add)|add // 0),
            jobs:($r|map(.workflows|map(.jobs)|add)|add // 0),
            jobs_lt60:($r|map(.workflows|map(.jobs_lt60)|add)|add // 0),
            cancelled_runs:($r|map(.workflows|map(.cancelled_runs)|add)|add // 0),
            real_min:((($r|map(.workflows|map(.real_min)|add)|add // 0)*10|round)/10),
            billed_ubicloud:($r|map(.workflows|map(.billed_ubicloud)|add)|add // 0),
            billed_github:($r|map(.workflows|map(.billed_github)|add)|add // 0),
            billed_github_pagado:($r|map(select(.public|not)|.workflows|map(.billed_github)|add)|add // 0)}}' \
  $(sed "s#.*#$TMP/&.agg#" "$TMP/names") >"$TMP/all.json"

if [ "$JSON" = 1 ]; then cat "$TMP/all.json"; exit 0; fi

jq -r '
  def pad(n): tostring | (. + (" " * n))[0:n];
  def rpad(n): tostring | ((" " * n) + .)[-n:];
  "ci-costo: \(.owner), últimos \(.days) días (desde \(.since))",
  "min fact. = ceil(dur/60) por job sin salteados · UBI = runners ubicloud-*, GH = runners de GitHub (pub = repo público, GH gratis)",
  "",
  (.repos[]|
    "\(.repo)\(if .public then "  [pub]" else "" end)",
    ("  " + ("WORKFLOW"|pad(34)) + ("CORR"|rpad(6)) + ("JOBS"|rpad(6)) + ("<60s"|rpad(6)) + ("REAL"|rpad(8)) + ("UBI"|rpad(7)) + ("GH"|rpad(7)) + ("CANC"|rpad(6)) + "  POR EVENTO"),
    (.workflows[]|
      "  " + (.workflow|pad(34)) + (.runs|rpad(6)) + (.jobs|rpad(6)) + (.jobs_lt60|rpad(6)) + (.real_min|rpad(8)) + (.billed_ubicloud|rpad(7)) + (.billed_github|rpad(7)) + (.cancelled_runs|rpad(6)) + "  " + (.events|to_entries|map("\(.key)=\(.value)")|join(" "))),
    "  → PRs con CI: \(.prs) · corridas por PR: \(.runs_per_pr // "-") · PRs mergeados: \(.merged_prs) · min fact./PR mergeado: \(.min_per_merged_pr // "-")",
    ""),
  "TOTAL  corridas \(.total.runs) · jobs \(.total.jobs) · <60s \(.total.jobs_lt60) · canceladas \(.total.cancelled_runs) · min reales \(.total.real_min|floor)",
  "       min facturados: UBI \(.total.billed_ubicloud) · GH \(.total.billed_github) (de los cuales \(.total.billed_github - .total.billed_github_pagado) en repos públicos, gratis)"
' "$TMP/all.json"
