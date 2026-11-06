# antiproc

🇫🇷 [Français](#-français) · 🇬🇧 [English](#-english)

---

## 🇫🇷 Français

**antiproc** est un petit outil anti-procrastination pour Ubuntu. Quand tu ouvres Facebook, il te redirige automatiquement vers Coursera, ou vers **n'importe quelle adresse de ton choix**.

Tout tient dans **un seul programme Python** (bibliothèque standard uniquement), qui fait à la fois :

- un **serveur DNS local** : il répond « `127.0.0.1` » pour `facebook.com` et ses sous-domaines, et relaie toutes les autres questions vers un vrai serveur DNS ;
- un **serveur HTTPS local** : il répond à toute requête par une redirection `302` vers l'adresse choisie (Coursera par défaut) ;
- la **configuration du DNS du système** (via `systemd-resolved`), annulée automatiquement à l'arrêt du service.

### Comment ça marche

```
Navigateur → systemd-resolved → antiproc (DNS, 127.0.0.2:53)
          → facebook.com = 127.0.0.1
          → antiproc (HTTPS, 127.0.0.1:443) → HTTP 302 → destination (Coursera par défaut / by default)
```

Un certificat local de confiance (créé avec [mkcert](https://github.com/FiloSottile/mkcert)) évite l'erreur HTTPS dans le navigateur. Tous les autres sites se résolvent normalement.

### Prérequis

- Ubuntu (ou dérivé) avec **systemd** et **systemd-resolved** (actif par défaut sur Ubuntu)
- un compte avec les droits `sudo`
- `python3` (déjà présent sur Ubuntu)
- `mkcert` et `libnss3-tools` : installés automatiquement par le script si besoin. Si `apt` ne trouve pas `mkcert`, active le dépôt *universe* : `sudo add-apt-repository universe`

### Installation

```bash
git clone https://github.com/TON-PSEUDO/antiproc.git
cd antiproc
chmod +x install.sh
./install.sh
```

Lance le script **sans `sudo`** : il l'utilise lui-même quand c'est nécessaire (le certificat doit être créé avec ton compte). Il te demande d'abord l'**adresse complète** de la page de redirection (appuie sur Entrée pour garder Coursera), puis affiche ce qu'il va faire et demande confirmation.

Tu peux aussi donner l'adresse directement :

```bash
./install.sh --target https://www.khanacademy.org/
```

Si tu écris l'adresse sans `https://`, il l'ajoute. Une adresse invalide est refusée (espaces, caractères interdits, ou adresse de Facebook lui-même, qui créerait une boucle).

Ensuite, **ferme complètement Firefox et rouvre-le**, puis ouvre `facebook.com` : tu dois arriver sur Coursera.

### Utilisation

| Action | Commande |
|---|---|
| Voir l'état et lancer les tests | `./install.sh --status` |
| **Changer l'adresse de redirection** (sans réinstaller) | `./install.sh --set-target https://exemple.org/page` (sans adresse, elle est demandée) |
| Suspendre (le DNS d'origine est rétabli) | `sudo systemctl stop antiproc` |
| Réactiver | `sudo systemctl start antiproc` |
| Ne plus démarrer au lancement du PC | `sudo systemctl disable --now antiproc` |
| Voir les messages du service | `journalctl -u antiproc -n 30` |
| **Internet ne marche plus** | `./install.sh --repair` |
| Tout désinstaller | `./install.sh --uninstall` |

Si tu changes de réseau (autre interface, par exemple du Wi-Fi vers l'Ethernet), redémarre le service : `sudo systemctl restart antiproc`.

### Ce que fait `install.sh`

1. demande l'adresse de redirection (ou lit `--target`) ;
2. installe les prérequis manquants (seulement ceux-là) ;
3. crée un certificat local pour `facebook.com` et l'installe dans `/etc/antiproc` ;
4. importe l'autorité locale dans Firefox (y compris la version snap) et désactive le DNS sécurisé (DoH) de Firefox, Chrome et Chromium, qui contourneraient sinon le DNS local ;
5. enregistre la destination dans `/etc/antiproc/config`, puis installe le programme dans `/usr/local/bin` et le service `antiproc` ;
6. ajoute une redirection HTTP à Apache, uniquement s'il est actif ;
7. teste le résultat.

Le script peut être relancé sans risque (mise à jour).

### Personnalisation

Dans `antiproc.py` :

- la destination n'est **pas** dans le code : elle se change avec `./install.sh --set-target` (stockée dans `/etc/antiproc/config`, ligne `CIBLE=...`, relue à chaque requête, donc sans redémarrage) ;
- `dns_reso()` : la liste des sites détournés ;
- `UPSTREAM` : le serveur DNS vers lequel les autres questions sont relayées (`1.1.1.1` par défaut).

Pour détourner un autre site, ajoute son nom à `dns_reso()` **et** dans la commande `mkcert` de `install.sh` (le certificat doit couvrir ce nom), puis relance `./install.sh`.

### Dépannage

- **Plus d'Internet** : `./install.sh --repair`, puis `./install.sh --status` pour comprendre.
- **Erreur « Address already in use »** : un autre programme occupe `127.0.0.2:53` ou `127.0.0.1:443`. Identifie-le avec `sudo ss -lunp | grep ':53 '` et `sudo ss -ltnp | grep ':443 '`. Un serveur web sur le port 80 est sans gravité (le navigateur passe en HTTPS pour Facebook).
- **Erreur de certificat dans le navigateur** : ferme complètement le navigateur et relance `./install.sh`.
- **Pas de redirection** : vide le cache ou utilise une fenêtre privée, et vérifie que le DNS sécurisé (DoH) est bien désactivé dans le navigateur.

### Limites et sécurité

- C'est un outil d'**auto-discipline**, pas un contrôle parental : n'importe qui avec les droits administrateur peut l'arrêter.
- Un VPN ou un navigateur qui impose son propre DNS peut le contourner.
- Seul Facebook est détourné par défaut, et l'IPv6 n'est pas géré (le navigateur retombe sur l'IPv4).
- `mkcert` crée une autorité de certification locale : **ne partage jamais** le dossier indiqué par `mkcert -CAROOT`, ni les fichiers `*.pem` de `/etc/antiproc`. Ils sont exclus du dépôt par le `.gitignore`.
- Pour retirer l'autorité de confiance après désinstallation : `mkcert -uninstall`.

---

## 🇬🇧 English

**antiproc** is a small anti-procrastination tool for Ubuntu. When you open Facebook, it automatically redirects you to Coursera, or to **any address you choose**.

Everything fits in **a single Python program** (standard library only) that provides:

- a **local DNS server**: it answers `127.0.0.1` for `facebook.com` and its subdomains, and forwards every other query to a real DNS server;
- a **local HTTPS server**: it answers every request with a `302` redirect to the address you chose (Coursera by default);
- the **system DNS configuration** (through `systemd-resolved`), automatically reverted when the service stops.

### How it works

```
Browser → systemd-resolved → antiproc (DNS, 127.0.0.2:53)
        → facebook.com = 127.0.0.1
        → antiproc (HTTPS, 127.0.0.1:443) → HTTP 302 → destination (Coursera par défaut / by default)
```

A locally trusted certificate (created with [mkcert](https://github.com/FiloSottile/mkcert)) avoids the HTTPS error in the browser. All other sites resolve normally.

### Requirements

- Ubuntu (or derivative) with **systemd** and **systemd-resolved** (enabled by default on Ubuntu)
- an account with `sudo` rights
- `python3` (already present on Ubuntu)
- `mkcert` and `libnss3-tools`: installed automatically by the script if missing. If `apt` cannot find `mkcert`, enable the *universe* repository: `sudo add-apt-repository universe`

### Installation

```bash
git clone https://github.com/YOUR-USERNAME/antiproc.git
cd antiproc
chmod +x install.sh
./install.sh
```

Run the script **without `sudo`**: it uses `sudo` itself when needed (the certificate must be created with your own account). It first asks for the **full address** of the redirect page (press Enter to keep Coursera), then shows what it is going to do and asks for confirmation.

You can also pass the address directly:

```bash
./install.sh --target https://www.khanacademy.org/
```

If you type the address without `https://`, it is added for you. An invalid address is rejected (spaces, forbidden characters, or a Facebook address, which would create a loop).

Then **fully close and reopen Firefox**, and open `facebook.com`: you should land on Coursera.

### Usage

| Action | Command |
|---|---|
| Show status and run tests | `./install.sh --status` |
| **Change the redirect address** (no reinstall) | `./install.sh --set-target https://example.org/page` (without an address, it is asked) |
| Pause (original DNS is restored) | `sudo systemctl stop antiproc` |
| Resume | `sudo systemctl start antiproc` |
| Stop it from starting at boot | `sudo systemctl disable --now antiproc` |
| View service logs | `journalctl -u antiproc -n 30` |
| **Internet stopped working** | `./install.sh --repair` |
| Uninstall everything | `./install.sh --uninstall` |

If you switch networks (a different interface, for example Wi-Fi to Ethernet), restart the service: `sudo systemctl restart antiproc`.

### What `install.sh` does

1. asks for the redirect address (or reads `--target`);
2. installs missing prerequisites (only those);
3. creates a local certificate for `facebook.com` and stores it in `/etc/antiproc`;
4. imports the local authority into Firefox (including the snap version) and disables DNS over HTTPS (DoH) in Firefox, Chrome and Chromium, which would otherwise bypass the local DNS;
5. saves the destination in `/etc/antiproc/config`, then installs the program in `/usr/local/bin` and the `antiproc` service;
6. adds an HTTP redirect to Apache, only if it is running;
7. tests the result.

The script is safe to run again (update).

### Customization

In `antiproc.py`:

- the destination is **not** in the code: change it with `./install.sh --set-target` (stored in `/etc/antiproc/config`, line `CIBLE=...`, re-read on every request, so no restart is needed);
- `dns_reso()`: the list of hijacked sites;
- `UPSTREAM`: the DNS server other queries are forwarded to (`1.1.1.1` by default).

To redirect another site, add its name to `dns_reso()` **and** to the `mkcert` command in `install.sh` (the certificate must cover that name), then run `./install.sh` again.

### Troubleshooting

- **No more Internet**: `./install.sh --repair`, then `./install.sh --status` to investigate.
- **"Address already in use" error**: another program is using `127.0.0.2:53` or `127.0.0.1:443`. Identify it with `sudo ss -lunp | grep ':53 '` and `sudo ss -ltnp | grep ':443 '`. A web server on port 80 is harmless (browsers switch to HTTPS for Facebook).
- **Certificate error in the browser**: fully close the browser and run `./install.sh` again.
- **No redirect**: clear the cache or use a private window, and check that DNS over HTTPS (DoH) is disabled in the browser.

### Limits and security

- This is a **self-discipline** tool, not parental control: anyone with administrator rights can stop it.
- A VPN, or a browser enforcing its own DNS, can bypass it.
- Only Facebook is redirected by default, and IPv6 is not handled (the browser falls back to IPv4).
- `mkcert` creates a local certificate authority: **never share** the folder shown by `mkcert -CAROOT`, nor the `*.pem` files in `/etc/antiproc`. They are excluded from the repository by `.gitignore`.
- To remove the trusted authority after uninstalling: `mkcert -uninstall`.
