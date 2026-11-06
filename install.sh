#!/bin/bash
# install.sh : installation, état, changement de destination, réparation et désinstallation d'antiproc
# Usage : ./install.sh [--target URL | --status | --set-target [URL] | --repair | --uninstall | --help] [-y]
# À lancer SANS sudo (le script l'utilise lui-même quand c'est nécessaire).

set -Eeuo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="/etc/antiproc/config"
CIBLE_DEFAUT="https://www.coursera.org/"
VHOST="/etc/apache2/sites-available/antiproc.conf"
CHROME_POL="/etc/opt/chrome/policies/managed/antiproc.json"
CHROMIUM_POL="/etc/chromium/policies/managed/antiproc.json"
SNAP_CHROMIUM_POL="/var/snap/chromium/current/policies/managed/antiproc.json"
TMP=""
CIBLE_FINALE=""

# ---------- Affichage ----------
if [ -t 1 ]; then
    R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else
    R=""; G=""; Y=""; B=""; N=""
fi
etape() { echo; echo "${B}[$1] $2${N}"; }
ok()    { echo "  ${G}✔${N} $*"; }
warn()  { echo "  ${Y}!${N} $*"; }
ko()    { echo "  ${R}✘${N} $*"; }

aide() {
    cat <<EOF
${B}antiproc${N} : redirige Facebook vers l'adresse de ton choix (DNS local + redirection HTTPS)

Usage : ./install.sh [option] [-y]

  (aucune)              installe ou met à jour antiproc (l'adresse de redirection est demandée)
  --target URL          installe en indiquant directement l'adresse de redirection
  --set-target [URL]    change l'adresse de redirection sans réinstaller
  --status              affiche l'état du service et lance les tests
  --repair              arrête antiproc et rétablit le DNS d'origine
                        (à utiliser si Internet ne fonctionne plus)
  --uninstall           supprime antiproc et ses réglages
  --help                affiche cette aide
  -y, --yes             n'affiche pas les demandes de confirmation
                        (adresse par défaut : celle déjà configurée, sinon Coursera)

Exemples :
  ./install.sh
  ./install.sh --target https://www.khanacademy.org/
  ./install.sh --set-target https://exemple.org/ma-page

Après installation :
  sudo systemctl stop antiproc       suspendre (DNS d'origine rétabli)
  sudo systemctl start antiproc      réactiver
  sudo systemctl disable --now antiproc   désactiver au démarrage
  journalctl -u antiproc -n 30       consulter les messages du service
EOF
}

# ---------- Lecture des options ----------
MODE="install"; AUTO=0; TARGET=""
while [ $# -gt 0 ]; do
    case "$1" in
        --status)    MODE="status" ;;
        --repair)    MODE="repair" ;;
        --uninstall) MODE="uninstall" ;;
        --set-target)
            MODE="settarget"
            if [ $# -gt 1 ] && [[ "$2" != -* ]]; then TARGET="$2"; shift; fi ;;
        --target)
            [ $# -gt 1 ] || { echo "--target demande une adresse complète."; exit 1; }
            TARGET="$2"; shift ;;
        -y|--yes)    AUTO=1 ;;
        -h|--help)   aide; exit 0 ;;
        *) echo "Option inconnue : $1"; aide; exit 1 ;;
    esac
    shift
done

if [ "$EUID" -eq 0 ]; then
    ko "Lance ce script sans sudo : il l'utilise lui-même quand il le faut."
    exit 1
fi

# ---------- Gestion des erreurs ----------
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; return 0; }
erreur() {
    ko "Erreur à la ligne $1. L'opération est interrompue."
    echo "  Si Internet ne répond plus : ./install.sh --repair"
}
trap cleanup EXIT
trap 'erreur $LINENO' ERR

# ---------- Fonctions utilitaires ----------
interface() {
    ip route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

profils_firefox() {   # profils Firefox classiques et snap
    local p
    for p in "$HOME"/.mozilla/firefox/*/ "$HOME"/snap/firefox/common/.mozilla/firefox/*/; do
        [ -f "${p}prefs.js" ] && echo "${p%/}"
    done
    return 0
}

confirmer() {
    [ "$AUTO" -eq 1 ] && return 0
    local r
    read -r -p "Continuer ? [o/N] " r
    [[ "$r" =~ ^[oOyY]$ ]] || { echo "Annulé."; exit 0; }
}

# Destination actuellement enregistrée (vide si aucune)
cible_actuelle() {
    sed -n 's/^CIBLE=//p' "$CONFIG" 2>/dev/null | head -1 || true
}

# Vérifie et normalise une adresse : écrit l'adresse corrigée sur la sortie standard,
# ou un message d'erreur sur la sortie d'erreur (code 1).
normaliser_url() {
    local u="$1" autorite hote
    u="${u#"${u%%[![:space:]]*}"}"; u="${u%"${u##*[![:space:]]}"}"   # retire les espaces aux extrémités
    [ -n "$u" ] || { ko "Adresse vide." >&2; return 1; }
    if [[ "$u" =~ [[:space:]] ]]; then
        ko "Adresse invalide : elle ne doit pas contenir d'espace." >&2
        return 1
    fi
    if [[ "$u" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]] && ! [[ "$u" =~ ^[Hh][Tt][Tt][Pp][Ss]?:// ]]; then
        ko "Adresse invalide : seuls http:// et https:// sont acceptés." >&2
        return 1
    fi
    [[ "$u" =~ ^[Hh][Tt][Tt][Pp][Ss]?:// ]] || u="https://$u"
    case "$u" in
        *[\"\'\\\`\<\>\$\|\^\{\}]*)
            ko "Adresse invalide : caractères interdits (guillemets, \\, \$, <, >, |, ^, {, })." >&2
            return 1 ;;
    esac
    autorite="${u#*://}"; autorite="${autorite%%[/?#]*}"
    if [[ "$autorite" == *@* ]]; then
        ko "Adresse invalide : les identifiants dans l'adresse (user@...) ne sont pas acceptés." >&2
        return 1
    fi
    hote="${autorite%%:*}"; hote="${hote,,}"
    if ! [[ "$hote" =~ ^[a-z0-9-]+(\.[a-z0-9-]+)+$ ]]; then
        ko "Adresse invalide : « $hote » n'est pas un nom de domaine (exemple : https://www.coursera.org/)." >&2
        return 1
    fi
    if [[ "$hote" =~ (^|\.)facebook\.com$ ]]; then
        ko "Redirection refusée : rediriger Facebook vers Facebook créerait une boucle." >&2
        return 1
    fi
    echo "$u"
}

# Détermine CIBLE_FINALE : option --target / argument, sinon question (défaut : adresse actuelle ou Coursera)
choisir_cible() {
    local defaut saisie
    defaut="$(cible_actuelle)"; defaut="${defaut:-$CIBLE_DEFAUT}"
    while true; do
        if [ -n "$TARGET" ]; then
            saisie="$TARGET"
        elif [ "$AUTO" -eq 1 ]; then
            saisie="$defaut"
        else
            read -r -p "Adresse complète de redirection [$defaut] : " saisie
            saisie="${saisie:-$defaut}"
        fi
        if CIBLE_FINALE="$(normaliser_url "$saisie")"; then return 0; fi
        # adresse invalide : on ne redemande qu'en mode interactif
        if [ -n "$TARGET" ] || [ "$AUTO" -eq 1 ]; then exit 1; fi
    done
}

ecrire_config() {
    sudo install -d -m 755 /etc/antiproc
    printf 'CIBLE=%s\n' "$1" | sudo tee "$CONFIG" >/dev/null
    sudo chmod 644 "$CONFIG"
}

# Redirection HTTP (port 80) via Apache, uniquement s'il est actif
ecrire_vhost() {
    if systemctl is-active --quiet apache2; then
        sudo tee "$VHOST" >/dev/null <<EOF
<VirtualHost *:80>
    ServerName facebook.com
    ServerAlias www.facebook.com m.facebook.com facebook
    Redirect 302 / $1
</VirtualHost>
EOF
        sudo a2ensite antiproc >/dev/null
        sudo systemctl reload apache2
        ok "Apache : redirection HTTP mise à jour"
    else
        ok "Apache absent ou inactif : rien à faire"
    fi
}

tester() {
    local fb ex loc attendue
    attendue="$(cible_actuelle)"
    fb=$(getent hosts facebook.com | awk 'NR==1{print $1}') || true
    ex=$(getent hosts example.com  | awk 'NR==1{print $1}') || true
    loc=$(curl -sI --max-time 5 --resolve facebook.com:443:127.0.0.1 https://facebook.com \
          | grep -i '^location:' | tr -d '\r' | sed 's/^[Ll]ocation: *//') || true
    if [ "$fb" = "127.0.0.1" ]; then ok "facebook.com → 127.0.0.1 (détourné)"
    else ko "facebook.com → ${fb:-aucune réponse} (attendu : 127.0.0.1)"; fi
    if [ -n "$ex" ]; then ok "example.com → $ex (résolution normale)"
    else ko "example.com ne se résout pas : vérifie UPSTREAM dans antiproc.py"; fi
    if [ -z "$loc" ]; then
        ko "Pas de redirection HTTPS (port 443 occupé ou certificat invalide ?)"
    elif [ -n "$attendue" ] && [ "$loc" != "$attendue" ]; then
        warn "Redirection HTTPS → $loc (adresse configurée : $attendue)"
    else
        ok "Redirection HTTPS → $loc"
    fi
}

# ---------- Mode : état ----------
if [ "$MODE" = "status" ]; then
    etape "État" "Service et tests"
    if systemctl is-active --quiet antiproc; then ok "Service antiproc actif"
    else ko "Service antiproc inactif"; fi
    echo "  Destination configurée : $(cible_actuelle | sed 's/^$/(aucune, défaut : Coursera)/')"
    itf="$(interface)"
    echo "  Interface : ${itf:-inconnue}"
    resolvectl status "$itf" 2>/dev/null | grep -E 'Current DNS Server|DNS Servers' | sed 's/^/  /' || true
    tester
    exit 0
fi

# ---------- Mode : changement de destination ----------
if [ "$MODE" = "settarget" ]; then
    etape "Destination" "Changement de l'adresse de redirection"
    [ -f /etc/systemd/system/antiproc.service ] \
        || { ko "antiproc n'est pas installé : lance d'abord ./install.sh"; exit 1; }
    echo "  Destination actuelle : $(cible_actuelle | sed 's/^$/(défaut : Coursera)/')"
    choisir_cible
    ecrire_config "$CIBLE_FINALE"
    ok "Nouvelle destination : $CIBLE_FINALE (prise en compte sans redémarrage)"
    if [ -f "$VHOST" ]; then ecrire_vhost "$CIBLE_FINALE"; fi
    tester
    echo "  Si le navigateur affiche encore l'ancienne page : fenêtre privée ou vidage du cache."
    exit 0
fi

# ---------- Mode : réparation ----------
if [ "$MODE" = "repair" ]; then
    etape "Réparation" "Arrêt du service et retour au DNS d'origine"
    sudo systemctl stop antiproc 2>/dev/null || true
    itf="$(interface)"
    [ -n "$itf" ] && sudo resolvectl revert "$itf" && ok "DNS rétabli sur $itf"
    sudo resolvectl flush-caches 2>/dev/null || true
    ok "Terminé. Teste ta connexion ; relance ./install.sh pour réactiver antiproc."
    exit 0
fi

# ---------- Mode : désinstallation ----------
if [ "$MODE" = "uninstall" ]; then
    echo "${B}Désinstallation d'antiproc${N} : service, programme, certificat, configuration, réglages navigateurs."
    confirmer
    sudo systemctl disable --now antiproc 2>/dev/null || true
    sudo rm -f /etc/systemd/system/antiproc.service /usr/local/bin/antiproc.py
    sudo systemctl daemon-reload
    sudo rm -rf /etc/antiproc
    sudo rm -f "$CHROME_POL" "$CHROMIUM_POL" "$SNAP_CHROMIUM_POL"
    if [ -f "$VHOST" ]; then
        sudo a2dissite antiproc >/dev/null || true
        sudo rm -f "$VHOST"
        sudo systemctl reload apache2
    fi
    while IFS= read -r p; do
        sed -i '/antiproc/d' "$p/user.js" 2>/dev/null || true
        certutil -D -d "sql:$p" -n mkcert-antiproc 2>/dev/null || true
    done < <(profils_firefox)
    ok "antiproc est désinstallé."
    echo "  Pour retirer aussi l'autorité de certification : mkcert -uninstall"
    exit 0
fi

# ---------- Mode : installation ----------
echo "${B}Installation d'antiproc${N}"
choisir_cible
echo
echo "Ce script va :"
echo "  1. installer les prérequis manquants (sans toucher aux autres paquets) ;"
echo "  2. créer un certificat local de confiance pour facebook.com ;"
echo "  3. importer ce certificat dans Firefox et désactiver le DoH des navigateurs ;"
echo "  4. installer le programme et le service systemd « antiproc » ;"
echo "  5. ajouter une redirection HTTP à Apache, s'il est actif ;"
echo "  6. tester le résultat."
echo "Facebook sera redirigé vers : ${B}${CIBLE_FINALE}${N}"
confirmer

etape "0/6" "Vérifications préalables"
[ -f "$DIR/antiproc.py" ]      || { ko "antiproc.py introuvable dans $DIR"; exit 1; }
[ -f "$DIR/antiproc.service" ] || { ko "antiproc.service introuvable dans $DIR"; exit 1; }
command -v systemctl >/dev/null || { ko "systemd est requis."; exit 1; }
[ -n "$(interface)" ]          || { ko "Aucune connexion réseau active (route par défaut introuvable)."; exit 1; }
ok "Fichiers du projet présents, réseau actif (interface $(interface))"
if grep -qE '^UPSTREAM *= *\("127\.0\.0\.1"' "$DIR/antiproc.py"; then
    warn "UPSTREAM pointe vers 127.0.0.1 : un serveur DNS doit y écouter (bind9, par exemple),"
    warn "sinon Internet ne fonctionnera plus. Valeur par défaut conseillée : 1.1.1.1"
fi
if ! systemctl is-active --quiet antiproc; then
    if ss -lun | grep -q '127\.0\.0\.2:53 '; then
        ko "Le port 53 de 127.0.0.2 est déjà utilisé par un autre programme."; exit 1
    fi
    if ss -ltn | grep -qE '127\.0\.0\.1:443 |0\.0\.0\.0:443 |\*:443 '; then
        warn "Le port 443 est déjà utilisé : la redirection HTTPS risque d'échouer."
    fi
fi

etape "1/6" "Prérequis"
PAQUETS=()
command -v python3  >/dev/null || PAQUETS+=(python3)
command -v mkcert   >/dev/null || PAQUETS+=(mkcert)
command -v certutil >/dev/null || PAQUETS+=(libnss3-tools)
command -v curl     >/dev/null || PAQUETS+=(curl)
command -v ip       >/dev/null || PAQUETS+=(iproute2)
if [ "${#PAQUETS[@]}" -gt 0 ]; then
    echo "  Paquets à installer : ${PAQUETS[*]}"
    sudo apt update
    sudo apt install -y "${PAQUETS[@]}"
fi
systemctl is-active --quiet systemd-resolved \
    || { ko "systemd-resolved n'est pas actif : arrêt."; exit 1; }
command -v resolvectl >/dev/null || { ko "resolvectl est introuvable : arrêt."; exit 1; }
ok "Prérequis satisfaits"

etape "2/6" "Certificat local"
mkcert -install
TMP="$(mktemp -d)"
mkcert -cert-file "$TMP/cert.pem" -key-file "$TMP/key.pem" \
    facebook facebook.com www.facebook.com m.facebook.com "*.facebook.com"
sudo install -d -m 755 /etc/antiproc
sudo install -m 644 "$TMP/cert.pem" /etc/antiproc/cert.pem
sudo install -m 600 "$TMP/key.pem"  /etc/antiproc/key.pem
ok "Certificat installé dans /etc/antiproc"

etape "3/6" "Navigateurs"
CA="$(mkcert -CAROOT)/rootCA.pem"
NB=0
while IFS= read -r p; do
    certutil -D -d "sql:$p" -n mkcert-antiproc 2>/dev/null || true
    certutil -A -d "sql:$p" -t "C,," -n mkcert-antiproc -i "$CA"
    grep -q antiproc "$p/user.js" 2>/dev/null \
        || echo 'user_pref("network.trr.mode", 5); // antiproc : DoH désactivé' >> "$p/user.js"
    NB=$((NB + 1))
done < <(profils_firefox)
if [ "$NB" -gt 0 ]; then ok "Firefox : $NB profil(s) configuré(s)"; else warn "Aucun profil Firefox trouvé"; fi
POL='{"DnsOverHttpsMode": "off"}'
if command -v google-chrome >/dev/null || command -v google-chrome-stable >/dev/null; then
    sudo install -d "$(dirname "$CHROME_POL")"
    echo "$POL" | sudo tee "$CHROME_POL" >/dev/null; ok "Chrome : DoH désactivé"
fi
if command -v chromium >/dev/null || command -v chromium-browser >/dev/null; then
    sudo install -d "$(dirname "$CHROMIUM_POL")"
    echo "$POL" | sudo tee "$CHROMIUM_POL" >/dev/null; ok "Chromium : DoH désactivé"
fi
if [ -d /var/snap/chromium ]; then
    sudo install -d "$(dirname "$SNAP_CHROMIUM_POL")"
    echo "$POL" | sudo tee "$SNAP_CHROMIUM_POL" >/dev/null; ok "Chromium (snap) : DoH désactivé"
fi

etape "4/6" "Programme, destination et service"
ecrire_config "$CIBLE_FINALE"
ok "Destination enregistrée : $CIBLE_FINALE"
sudo install -m 755 "$DIR/antiproc.py"      /usr/local/bin/antiproc.py
sudo install -m 644 "$DIR/antiproc.service" /etc/systemd/system/antiproc.service
sudo systemctl daemon-reload
sudo systemctl enable antiproc >/dev/null 2>&1
sudo systemctl restart antiproc
ok "Service antiproc installé et démarré"

etape "5/6" "Apache (facultatif)"
ecrire_vhost "$CIBLE_FINALE"

etape "6/6" "Tests"
sleep 2
if systemctl is-active --quiet antiproc; then ok "Service actif"
else ko "Le service s'est arrêté : journalctl -u antiproc -n 30"; fi
tester

echo
echo "${B}Terminé.${N} Ferme complètement Firefox puis rouvre-le pour appliquer les réglages."
echo "Commandes utiles : ./install.sh --status | --set-target | --repair | --uninstall"
