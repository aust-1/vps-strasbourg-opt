#!/usr/bin/env bash
# Contrôle de conformité de /opt, sans rien modifier. À lancer avant tout commit/déploiement.
# Vérifie : scripts (forme, LF, bit exécutable, shellcheck), composes, Caddyfile, permissions,
# cohérence des sous-modules, et le contrat de chaque app/service (nom de projet, réseau,
# ports, alias uniques, cibles des reverse_proxy).
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/perms.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/perms.sh"

usage() {
  cat <<'EOF'
Usage : scripts/check.sh [--strict] [--skip-shellcheck] [-h]

Ne modifie rien. Affiche OK / ATTENTION / ÉCHEC pour chaque contrôle.

Options :
  --strict            un contrôle impossible à réaliser (shellcheck absent…) devient un échec
  --skip-shellcheck   saute shellcheck (déjà lancé ailleurs)
  -h, --help          cette aide

Codes de sortie : 0 aucun échec ; 1 au moins un échec ; 2 usage ; 3 prérequis.
EOF
}

STRICT=0
SKIP_SHELLCHECK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict)
      STRICT=1
      shift
      ;;
    --skip-shellcheck)
      SKIP_SHELLCHECK=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) usage_error "option inconnue : $1" ;;
  esac
done

require_repo
require_docker
cd "$OPT_ROOT"

FAILURES=0
WARNINGS=0
pass() { printf '  OK        %s\n' "$*"; }
fail() {
  printf '  ÉCHEC     %s\n' "$*"
  FAILURES=$((FAILURES + 1))
}
caution() {
  printf '  ATTENTION %s\n' "$*"
  WARNINGS=$((WARNINGS + 1))
}
# skipped <message> : contrôle irréalisable ; échec seulement avec --strict.
skipped() { if [[ "$STRICT" == "1" ]]; then fail "$*"; else caution "$*"; fi; }
section() { printf '\n== %s\n' "$*"; }

# --- 1. Scripts --------------------------------------------------------------
section "scripts"
for f in scripts/*.sh scripts/lib/*.sh; do
  [[ -f "$f" ]] || continue
  problems=""
  if [[ "$f" == scripts/lib/* ]]; then
    [[ "$(git ls-files -s -- "$f" | cut -c1-6)" == "100644" ]] || problems+=" mode git != 100644;"
  else
    [[ "$(head -n 1 "$f")" == "#!/usr/bin/env bash" ]] || problems+=" shebang;"
    grep -q '^set -euo pipefail$' "$f" || problems+=" set -euo pipefail absent;"
    [[ "$(git ls-files -s -- "$f" | cut -c1-6)" == "100755" ]] || problems+=" mode git != 100755;"
  fi
  if grep -q $'\r' "$f"; then problems+=" fins de ligne CRLF;"; fi
  if [[ -z "$problems" ]]; then pass "$f"; else fail "$f :$problems"; fi
done

if [[ "$SKIP_SHELLCHECK" == "0" ]]; then
  if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -x -P SCRIPTDIR -S warning scripts/*.sh scripts/lib/*.sh; then
      pass "shellcheck (local)"
    else
      fail "shellcheck"
    fi
  elif docker image inspect koalaman/shellcheck:stable >/dev/null 2>&1 \
    || docker pull -q koalaman/shellcheck:stable >/dev/null 2>&1; then
    if docker run --rm -v "$OPT_ROOT":/mnt:ro -w /mnt koalaman/shellcheck:stable \
      -x -P SCRIPTDIR -S warning scripts/*.sh scripts/lib/*.sh; then
      pass "shellcheck (conteneur)"
    else
      fail "shellcheck"
    fi
  else
    skipped "shellcheck indisponible (ni local ni image Docker)"
  fi
fi

# --- 2. Permissions ------------------------------------------------------------
section "permissions"
perms_process check
if [[ "$PERMS_VIOLATIONS" -eq 0 ]]; then
  pass "permissions conformes"
else
  fail "$PERMS_VIOLATIONS permission(s) non conforme(s) (scripts/fix-perms.sh)"
fi

# --- 3. Git ----------------------------------------------------------------
section "git et sous-modules"
declare -A GITLINKS=() DECLARED=()
while read -r mode _ _ path; do
  [[ "$mode" == "160000" ]] && GITLINKS[$path]=1
done < <(git ls-files -s)
if [[ -f .gitmodules ]]; then
  while read -r _ path; do DECLARED[$path]=1; done < <(git config -f .gitmodules --get-regexp '\.path$')
fi
ok=1
for p in "${!GITLINKS[@]}"; do
  [[ -n "${DECLARED[$p]:-}" ]] || {
    fail "sous-module $p sans entrée dans .gitmodules"
    ok=0
  }
  [[ "$p" == apps/* ]] || {
    fail "sous-module hors de apps/ : $p"
    ok=0
  }
done
for p in "${!DECLARED[@]}"; do
  [[ -n "${GITLINKS[$p]:-}" ]] || {
    fail "$p déclaré dans .gitmodules mais absent de l'index"
    ok=0
  }
done
for d in "$APPS_DIR"/*/; do
  [[ -d "$d" ]] || continue
  rel="apps/$(basename "$d")"
  [[ -n "${GITLINKS[$rel]:-}" ]] || {
    fail "$rel n'est pas un sous-module (scripts/app-add.sh)"
    ok=0
  }
done
[[ "$ok" == "1" ]] && pass "sous-modules cohérents (${#GITLINKS[@]})"
if [[ -f .gitmodules ]] && grep -qE 'url *= *(file://|/|\.)' .gitmodules; then
  caution ".gitmodules contient une URL locale (file://, chemin) : à réserver aux tests"
fi

if [[ -z "$(git ls-files -- containerd)" ]]; then pass "containerd/ non versionné"; else fail "containerd/ est suivi par git"; fi
secrets="$(git ls-files | grep -E '(^|/)\.env(\.[^/]*)?$' | grep -vE '\.example$' || true)"
if [[ -z "$secrets" ]]; then pass "aucun .env versionné"; else fail ".env versionné(s) : ${secrets//$'\n'/, }"; fi

# --- 4. Composes et contrat des unités -------------------------------------
section "composes et contrat"
declare -A ALIAS_OWNER=() CONTAINER_OWNER=()

# compose_render <dossier> : compose résolu ; retourne 1 avec le message d'erreur sur stdout.
compose_render() {
  local dir="$1" out
  if [[ -f "$dir/.env" ]]; then
    out="$(cd "$dir" && docker compose config 2>&1)" || {
      printf '%s' "$out"
      return 1
    }
  elif [[ -f "$dir/.env.example" ]]; then
    out="$(cd "$dir" && docker compose --env-file .env.example config 2>&1)" || {
      printf '%s' "$out"
      return 1
    }
  else
    out="$(cd "$dir" && docker compose config 2>&1)" || {
      printf '%s' "$out"
      return 1
    }
  fi
  printf '%s' "$out"
}

check_unit() {
  local dir="$1" kind="$2" name rendered project a c host
  name="$(basename "$dir")"
  local -a aliases=()

  if ! rendered="$(compose_render "$dir")"; then
    if grep -q 'required variable' <<<"$rendered"; then
      caution "$kind/$name : variable obligatoire sans valeur dans .env(.example) : $(grep -m1 'required variable' <<<"$rendered")"
      return 0
    fi
    fail "$kind/$name : docker compose config invalide : $(head -n 3 <<<"$rendered" | tr '\n' ' ')"
    return 0
  fi
  pass "$kind/$name : compose valide"

  project="$(awk '/^name:/ {print $2; exit}' <<<"$rendered")"
  if [[ "$project" == "$name" ]]; then
    pass "$kind/$name : nom de projet « $project » = nom du dossier (volumes stables)"
  else
    fail "$kind/$name : nom de projet « $project » ≠ dossier « $name » (les volumes changeraient : ajouter name: $name)"
  fi

  if grep -qE '^\s+published:' <<<"$rendered"; then
    fail "$kind/$name : publie un port sur l'hôte (seul le proxy le peut)"
  fi
  if ! grep -qE '^\s+name: '"$PROXY_NETWORK"'$' <<<"$rendered" || ! grep -q 'external: true' <<<"$rendered"; then
    fail "$kind/$name : réseau externe « $PROXY_NETWORK » non déclaré"
  fi
  if grep -qE '^\s+privileged: true' <<<"$rendered"; then
    fail "$kind/$name : conteneur privilégié"
  fi
  if grep -q '/var/run/docker.sock' <<<"$rendered"; then
    fail "$kind/$name : monte docker.sock"
  fi

  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    aliases+=("$a")
    if [[ -n "${ALIAS_OWNER[$a]:-}" && "${ALIAS_OWNER[$a]}" != "$name" ]]; then
      fail "alias réseau « $a » en double : $name et ${ALIAS_OWNER[$a]}"
    fi
    ALIAS_OWNER[$a]="$name"
  done < <(awk '/^[[:space:]]+aliases:/ {ina=1; next} ina && /^[[:space:]]+- / {sub(/^[[:space:]]+- /,""); print; next} {ina=0}' <<<"$rendered")

  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    if [[ -n "${CONTAINER_OWNER[$c]:-}" && "${CONTAINER_OWNER[$c]}" != "$name" ]]; then
      fail "container_name « $c » en double : $name et ${CONTAINER_OWNER[$c]}"
    fi
    CONTAINER_OWNER[$c]="$name"
  done < <(awk '/^[[:space:]]+container_name:/ {print $2}' <<<"$rendered")

  local missing=""
  [[ -f "$dir/.env.example" ]] || missing+=" .env.example"
  [[ -f "$dir/Caddyfile" ]] || caution "$kind/$name : pas de Caddyfile (aucune route publique)"
  if [[ -n "$missing" ]]; then fail "$kind/$name : fichier(s) manquant(s) :$missing"; fi

  if [[ -f "$dir/Caddyfile" ]]; then
    while IFS= read -r host; do
      [[ -n "$host" ]] || continue
      if [[ " ${aliases[*]:-} " == *" $host "* ]]; then
        pass "$kind/$name : reverse_proxy → $host (alias déclaré)"
      else
        fail "$kind/$name : reverse_proxy → « $host » n'est pas un alias réseau de l'unité (aliases : ${aliases[*]:-aucun})"
      fi
    done < <(grep -oE 'reverse_proxy +[a-z0-9._-]+' "$dir/Caddyfile" | awk '{print $2}' | sed 's/^https\?:\/\///' | sort -u)
  fi

  if [[ "$kind" == "apps" ]] && ! git -C "$dir" check-ignore -q .env 2>/dev/null; then
    fail "$kind/$name : son .gitignore n'ignore pas .env"
  fi
}

if [[ -f "$PROXY_COMPOSE" ]]; then
  if (cd "$PROXY_DIR" && docker compose config -q 2>/dev/null); then
    pass "proxy : compose valide"
  else
    fail "proxy : docker compose config invalide"
  fi
else
  fail "proxy/docker-compose.yml manquant"
fi

while IFS= read -r unit; do
  if [[ "$unit" == "$APPS_DIR"/* ]]; then check_unit "$unit" apps; else check_unit "$unit" services; fi
done < <(list_units)

# --- 5. Caddy --------------------------------------------------------------
section "caddy"
if out="$("$OPT_ROOT/scripts/routes-sync.sh" --validate-only 2>&1)"; then
  pass "Caddyfile assemblés valides"
else
  fail "Caddyfile invalides : $(tail -n 3 <<<"$out" | tr '\n' ' ')"
fi

echo
if [[ "$FAILURES" -eq 0 ]]; then
  log "contrôle terminé : aucun échec ($WARNINGS avertissement(s))"
else
  err "$FAILURES échec(s), $WARNINGS avertissement(s)"
  exit 1
fi
