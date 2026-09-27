# shellcheck shell=bash
# Règles de permissions : SOURCE DE VÉRITÉ UNIQUE.
# Utilisé par fix-perms.sh (applique) et check.sh (audite). À sourcer après common.sh.
#
# Règles (Linux/GNU stat) :
#   scripts/*.sh          755   exécutables
#   scripts/lib/*.sh      644   sourcés, jamais exécutés
#   scripts/, scripts/lib 755
#   .env, .env.* (hors .env.example) de chaque app/service et du proxy : 600 (secrets)
#   proxy/sites           755, fichiers *.caddy 644
#   backups/ (dépôt) et $BACKUP_DIR s'ils existent : 700 (contiennent des secrets)
# Jamais touchés : containerd/, .git/, et le contenu des sous-modules (hors .env).

PERMS_VIOLATIONS=0
PERMS_FIXED=0

# _perms_enforce <apply|check> <mode> <chemin>
_perms_enforce() {
  local action="$1" want="$2" path="$3" have
  [[ -e "$path" ]] || return 0
  have="$(stat -c '%a' "$path")"
  [[ "$have" == "$want" ]] && return 0
  if [[ "$action" == "apply" ]]; then
    run chmod "$want" "$path"
    log "chmod $want (était $have) : ${path#"$OPT_ROOT"/}"
    PERMS_FIXED=$((PERMS_FIXED + 1))
  else
    err "permissions ${have} au lieu de ${want} : ${path#"$OPT_ROOT"/}"
    PERMS_VIOLATIONS=$((PERMS_VIOLATIONS + 1))
  fi
}

# perms_env_files : chemins des fichiers de secrets (.env, .env.*) hors .env.example.
perms_env_files() {
  local dir f
  for dir in "$PROXY_DIR" "$APPS_DIR"/*/ "$SERVICES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    for f in "${dir%/}"/.env "${dir%/}"/.env.*; do
      [[ -f "$f" && "$f" != *.example ]] && printf '%s\n' "$f"
    done
  done
}

# perms_process <apply|check>
perms_process() {
  local action="$1" f
  PERMS_VIOLATIONS=0
  PERMS_FIXED=0

  _perms_enforce "$action" 755 "$OPT_ROOT/scripts"
  _perms_enforce "$action" 755 "$OPT_ROOT/scripts/lib"
  for f in "$OPT_ROOT"/scripts/*.sh; do
    [[ -f "$f" ]] && _perms_enforce "$action" 755 "$f"
  done
  for f in "$OPT_ROOT"/scripts/lib/*.sh; do
    [[ -f "$f" ]] && _perms_enforce "$action" 644 "$f"
  done

  while IFS= read -r f; do
    _perms_enforce "$action" 600 "$f"
  done < <(perms_env_files)

  _perms_enforce "$action" 755 "$PROXY_SITES_DIR"
  for f in "$PROXY_SITES_DIR"/*.caddy; do
    [[ -f "$f" ]] && _perms_enforce "$action" 644 "$f"
  done

  _perms_enforce "$action" 700 "$OPT_ROOT/backups"
  [[ -n "${BACKUP_DIR:-}" ]] && _perms_enforce "$action" 700 "$BACKUP_DIR"
  return 0
}
