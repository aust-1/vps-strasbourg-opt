#!/usr/bin/env bash
# Test de scripts/update.sh face aux commits locaux des déploiements automatiques (app-bump.sh),
# et du verrou partagé. Dépôts git jetables dans un dossier temporaire : ni Docker, ni root,
# ni réseau, aucun effet hors de ce dossier.
#
# Depuis la racine du dépôt opt :  bash tests/update-reconcile.sh
# Dernière ligne attendue : « TOUT EST VERT ».
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always GIT_CONFIG_KEY_1=init.defaultBranch GIT_CONFIG_VALUE_1=main
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export OPT_LOCK="$W/opt.lock"
FAIL=0
# Cette machine peut avoir un compte gh-deploy : update.sh relancerait deploy-install.sh (root).
mkdir -p "$W/bin" && printf '#!/bin/sh\n[ "$1" = gh-deploy ] && exit 1\nexec /usr/bin/id "$@"\n' > "$W/bin/id" && chmod +x "$W/bin/id"
export PATH="$W/bin:$PATH"
ok() { printf '  OK    %s\n' "$*"; }
ko() {
  printf '  ÉCHEC %s\n' "$*"
  FAIL=1
}

git init -q --bare "$W/demo.git"
git clone -q "$W/demo.git" "$W/demo-work" 2> /dev/null
(cd "$W/demo-work" && echo v1 > f && git add f && git commit -qm v1 && git push -q origin HEAD:main)
git init -q --bare "$W/opt.git"
git clone -q "$W/opt.git" "$W/ws" 2> /dev/null
(cd "$W/ws" && cp -a "$SRC/scripts" . && mkdir -p proxy/sites services && touch proxy/sites/.gitkeep \
  && git submodule add -q "$W/demo.git" apps/demo && git add -A && git commit -qm init && git push -q origin HEAD:main)
git clone -q --recurse-submodules "$W/opt.git" "$W/opt" 2> /dev/null
S="$W/opt"
dv() { (cd "$W/demo-work" && echo "$1" > f && git commit -qam "$1" && git push -q origin HEAD:main && git rev-parse HEAD); }
deploy() { # simule opt-deploy : checkout de origin/main puis app-bump.sh
  git -C "$S/apps/demo" fetch -q origin && git -C "$S/apps/demo" checkout -q --detach origin/main
  "$S/scripts/app-bump.sh" --to "$(git -C "$S/apps/demo" rev-parse --short HEAD)" demo > /dev/null
}
ws_push() { (cd "$W/ws" && git pull -q --recurse-submodules=no && eval "$1" && git push -q origin HEAD:main); }
upd() {
  rc=0
  "$S/scripts/update.sh" --no-routes "$@" > "$W/out" 2>&1 || rc=$?
}

echo "== A : déploiement local plus récent, doc poussée depuis le poste"
v2="$(dv v2)"
deploy
ws_push 'echo doc > README && git add README && git commit -qm doc'
upd
[[ "$rc" == 0 ]] && ok "code 0" || {
  ko "code $rc"
  cat "$W/out"
}
[[ "$(git -C "$S" rev-parse HEAD~1)" == "$(git -C "$S" rev-parse origin/main)" ]] && ok "HEAD = origin/main + 1 commit" || ko "historique"
[[ "$(git -C "$S" rev-parse HEAD:apps/demo)" == "$v2" ]] && ok "pointeur demo conservé sur le déployé" || ko "pointeur demo"
[[ "$(git -C "$S/apps/demo" rev-parse HEAD)" == "$v2" ]] && ok "sous-module toujours sur v2" || ko "sous-module"
[[ -f "$S/README" ]] && ok "commit doc reçu" || ko "doc absente"
git -C "$S" for-each-ref refs/opt-update | grep -q avant- && ok "ancien HEAD sauvegardé" || ko "pas de ref de sauvegarde"
git -C "$S" log -1 --format=%s | grep -q 'chore(apps): demo suit' && ok "message de commit" || ko "message"
[[ -z "$(git -C "$S" status --porcelain)" ]] && ok "arbre propre" || {
  ko "arbre sale"
  git -C "$S" status --short
}

echo "== B : le poste a avancé demo plus loin que le déployé"
v3="$(dv v3)"
v4="$(dv v4)"
git -C "$S/apps/demo" fetch -q origin
git -C "$S/apps/demo" checkout -q --detach "$v3"
"$S/scripts/app-bump.sh" --to "${v3:0:7}" demo > /dev/null
ws_push "git -C apps/demo fetch -q && git -C apps/demo checkout -q $v4 && git commit -qam 'bump demo v4'"
upd
[[ "$rc" == 0 ]] && ok "code 0" || {
  ko "code $rc"
  cat "$W/out"
}
[[ "$(git -C "$S" rev-parse HEAD)" == "$(git -C "$S" rev-parse origin/main)" ]] && ok "HEAD = origin/main (aucun réalignement)" || ko "historique B"
[[ "$(git -C "$S/apps/demo" rev-parse HEAD)" == "$v4" ]] && ok "sous-module avancé sur v4" || ko "sous-module B"
grep -q "à redéployer : scripts/app-deploy.sh demo" "$W/out" && ok "demo signalé à redéployer" || ko "pas de signalement"

echo "== C : commit local hors pointeurs : refus, rien modifié"
(cd "$S" && echo x > local && git add local && git commit -qm "correctif local")
ws_push 'echo doc2 >> README && git commit -qam doc2'
before="$(git -C "$S" rev-parse HEAD)"
upd
[[ "$rc" == 4 ]] && ok "code 4" || {
  ko "code $rc"
  cat "$W/out"
}
[[ "$(git -C "$S" rev-parse HEAD)" == "$before" ]] && ok "HEAD inchangé" || ko "HEAD modifié"
grep -q "runbook" "$W/out" && ok "procédure indiquée" || ko "pas de procédure"
git -C "$S" reset -q --hard origin/main

echo "== D : historiques sans lien (force-push de l'app) : refus"
dv v5 > /dev/null
deploy
(cd "$W/demo-work" && git checkout -q --orphan autre && echo z > f && git add f && git commit -qm refait && git push -q -f origin HEAD:main)
z="$(git -C "$W/demo-work" rev-parse HEAD)"
ws_push "git -C apps/demo fetch -q && git -C apps/demo checkout -q $z && git commit -qam 'bump demo refait'"
before="$(git -C "$S" rev-parse HEAD)"
upd
[[ "$rc" == 4 ]] && ok "code 4" || {
  ko "code $rc"
  cat "$W/out"
}
[[ "$(git -C "$S" rev-parse HEAD)" == "$before" ]] && ok "HEAD inchangé" || ko "HEAD modifié"
git -C "$S" reset -q --hard origin/main
git -C "$S" submodule update -q

echo "== E : à jour, commits locaux seulement"
(cd "$W/demo-work" && echo v6 > f && git commit -qam v6 && git push -q origin HEAD:main)
deploy
upd
[[ "$rc" == 0 ]] && grep -q "non poussé" "$W/out" && ok "rien à récupérer, commits locaux signalés" || {
  ko "E code $rc"
  cat "$W/out"
}

echo "== F : verrou tenu par une autre opération"
(
  flock 8
  sleep 4
) 8> "$OPT_LOCK" &
sleep 0.5
rc=0
OPT_LOCK_TIMEOUT=1 "$S/scripts/update.sh" --no-routes > "$W/out" 2>&1 || rc=$?
[[ "$rc" == 1 ]] && grep -q "verrou" "$W/out" && ok "délai dépassé : code 1, message clair" || {
  ko "F code $rc"
  cat "$W/out"
}
t0=$SECONDS
upd
wait
[[ "$rc" == 0 && $((SECONDS - t0)) -ge 2 ]] && grep -q "attente du verrou" "$W/out" && ok "attend la fin de l'autre opération puis passe" || {
  ko "F2 code $rc"
  cat "$W/out"
}
upd --dry-run
[[ "$rc" == 0 ]] && ok "dry-run sans verrou" || {
  ko "dry-run $rc"
  cat "$W/out"
}

[[ "$FAIL" == 0 ]] && echo "TOUT EST VERT" || {
  echo "DES ÉCHECS"
  exit 1
}
