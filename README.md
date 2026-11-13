<div align="center">
  <h1>🛡️ Script Automatisé Node.js + Caddy + Coraza WAF</h1>
  <p>
    <strong>Script Bash tout-en-un pour déployer une web-app Node.js derrière un Reverse Proxy HTTPS et un WAF</strong>
  </p>
  <p>
    <img src="https://img.shields.io/badge/NODE.JS-339933?style=for-the-badge&logo=nodedotjs&logoColor=white" alt="Node.js" />
    <img src="https://img.shields.io/badge/Reverse%20Proxy-Caddy-1F88C0?style=for-the-badge&logo=caddy&logoColor=white" alt="Caddy" />
    <img src="https://img.shields.io/badge/WAF-Coraza%20%2B%20OWASP%20CRS-DC2626?style=for-the-badge&logo=securityscorecard&logoColor=white" alt="Coraza WAF" />
  </p>
</div>

---

Ce repo contient un script Bash (`caddy-coraza.sh`) conçu pour automatiser le déploiement complet et sécurisé d'une application **Node.js** sur un serveur Linux (Debian).

Il met en place une architecture de production moderne combinant **Caddy** (serveur web / reverse proxy avec HTTPS automatique) et **Coraza WAF** (pare-feu applicatif web) couplé aux règles de sécurité **OWASP CRS**.

## 📚 Concepts Clés : Reverse Proxy & WAF

Avant d'utiliser le script, voici comment fonctionne l'architecture mise en place et pourquoi elle est essentielle pour sécuriser une application web.

### 1. Qu'est-ce qu'un Reverse Proxy ? (Exemple : Caddy)

Un **Reverse Proxy** est un serveur placé en première ligne entre les visiteurs et votre application backend (ici, votre serveur Node.js). Les utilisateurs ne communiquent jamais directement avec votre code Node.js ; ils passent obligatoirement par le reverse proxy.

**Pourquoi utiliser Caddy comme Reverse Proxy ?**

* **Isolation et Sécurité :** Votre application Node.js tourne uniquement en local (`127.0.0.1:3000`). Elle n'est pas exposée directement sur Internet.
* **HTTPS Automatique :** Caddy gère nativement la génération et le renouvellement des certificats SSL/TLS (via Let's Encrypt) sans aucune configuration complexe.
* **Performance :** Il prend en charge la compression moderne des données (`zstd` et `gzip`) et le protocole HTTP/3 avant de transmettre les requêtes à Node.js.
* **En-têtes de sécurité :** Il ajoute automatiquement des protections HTTP (HSTS, anti-clickjacking `X-Frame-Options`, masquage de la signature du serveur).

```text
[ Visiteur (HTTPS) ] ──▶ [ Caddy (Reverse Proxy :443) ] ──▶ [ App Node.js (Local 127.0.0.1:3000) ]
```

### 2. Qu'est-ce qu'un WAF ? (Exemple : Coraza WAF)

Un **WAF** (*Web Application Firewall* ) agit comme un garde du corps spécialisé dans le trafic HTTP/HTTPS. Contrairement à un pare-feu réseau classique qui se contente d'ouvrir ou fermer des ports (ex: port 80 ou 443), le WAF **inspecte le contenu même des requêtes web** (URL, en-têtes, cookies, corps JSON/formulaires).

**Pourquoi utiliser Coraza WAF avec les règles OWASP CRS ?**

* **Protection contre les attaques web :** Coraza détecte et bloque les tentatives d'injections SQL, les failles XSS, les inclusions de fichiers locaux (LFI), ou encore les bots malveillants.
* **Intégration native dans Caddy :** Coraza est compilé directement au cœur de Caddy. Chaque requête entrante est analysée *avant* même d'atteindre votre application Node.js.
* **Deux modes de fonctionnement :**
  * `DetectionOnly` **(Observation)** : Analyse le trafic et enregistre les alertes dans un fichier de log sans bloquer les utilisateurs.
  * `On` **(Blocage strict)** : Rejette immédiatement toute requête suspecte avec une erreur `403 Forbidden`.

```text
[ Requête Malveillante ] ──▶ [ Caddy + Coraza WAF ] ──❌ Bloquée (403 Forbidden)
[ Requête Légitime     ] ──▶ [ Caddy + Coraza WAF ] ──✅ Transmise à Node.js
```

## ⚙️ Ce que fait le script

Le script `caddy-coraza.sh` automatise l'intégralité de l'installation et de la configuration en **3 phases interactives** suivies de **6 étapes d'exécution**.

### Phase 1 : Assistant interactif

1. **Vérification DNS :** S'assure que votre nom de domaine pointe déjà vers l'adresse IP publique du serveur (indispensable pour la validation SSL de Caddy).
2. **Choix de l'application :**
   * *Option A :* Déploie votre propre projet Node.js existant (avec sauvegarde automatique si le dossier cible existe déjà).
   * *Option B :* Génère une application de démonstration Express fonctionnelle pour tester l'infrastructure.
3. **Choix du mode WAF :** Vous permet de choisir entre le mode **Observation** ou **Blocage strict**.

### Phase 2 : Installation et configuration automatisée (6 étapes)

1. **Sécurisation réseau (UFW) :** Installe les dépendances système et configure le pare-feu UFW pour bloquer tout trafic entrant par défaut, à l'exception des ports `22` (SSH), `80` (HTTP) et `443` (HTTPS/HTTP3).
2. **Environnement Node.js & PM2 :** Installe **Node.js 20 LTS** et le gestionnaire de processus **PM2**. Configure votre application pour qu'elle écoute uniquement sur `127.0.0.1` et redémarre automatiquement en cas de reboot du serveur. *(Inclut une alerte de sécurité si votre code force l'écoute sur `0.0.0.0`)*.
3. **Compilation sur mesure (xcaddy) :** Télécharge et compile **Caddy** en y intégrant directement le module officiel `coraza-caddy`.
4. **Règles de sécurité OWASP CRS :** Crée un utilisateur système isolé `caddy`, télécharge le jeu de règles officiel **OWASP Core Rule Set** et applique la configuration recommandée de Coraza.
5. **Génération du `Caddyfile` :** Configure le routage vers votre port local, active l'inspection des corps de requêtes JSON pour Coraza, active la compression (`zstd`/`gzip`) et injecte les en-têtes de sécurité HTTP.
6. **Service Systemd :** Valide la configuration, crée le service `caddy.service` et démarre le serveur web en arrière-plan.

## 🚀 Prérequis & Utilisation

### Prérequis

* Un serveur VPS sous **Debian** ou **Ubuntu**.
* Un accès `root` ou `sudo`.
* Un nom de domaine dont l'enregistrement DNS (`A` ou `AAAA`) pointe vers l'IP du serveur.

### Installation et lancement

1. **Téléchargez le script et rendez-le exécutable :**
   ```bash
   chmod +x caddy-coraza.sh
   ```

2. **Exécutez le script en via `sudo` :**
   ```bash
   sudo ./caddy-coraza.sh <votre-domaine.com> <nom-du-dossier-app>
   ```
   *Exemple :*
   ```bash
   sudo ./caddy-coraza.sh mon-application.fr mon-projet
   ```

3. **Suivez les instructions à l'écran** pour renseigner le chemin de votre code (ou choisir l'application de démonstration) et le mode du WAF.

## 🛠️ Commandes utiles après le déploiement

* **Consulter les alertes et blocages du WAF Coraza :**
  ```bash
  sudo tail -f /var/log/caddy/coraza_audit.log
  ```

* **Passer le WAF du mode Observation (`DetectionOnly`) au mode Blocage (`On`) :**
  ```bash
  sudo sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' /etc/caddy/coraza.conf
  sudo systemctl reload caddy
  ```

* **Vérifier l'état de l'application Node.js (avec l'utilisateur non-root) :**
  ```bash
  pm2 status
  pm2 logs
  ```

* **Vérifier l'état du service Caddy :**
  ```bash
  sudo systemctl status caddy
  ```

---
<div align="center">

Conçu par **LiL PouLaY**  
*Formats supportés : Node.js • Bash*

[![Github: LiLPouLe](https://img.shields.io/badge/Github-LiLPouLe-10b981?style=social&logo=github&logoColor=000000)](https://github.com/LiLPouLe)

</div>