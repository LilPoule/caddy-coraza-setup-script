#!/bin/bash
set -euo pipefail

# --- Verifications initiales ---
if [ "$EUID" -ne 0 ]; then
  echo "[ERREUR] Executez ce script avec sudo (sudo $0 <domaine> <nom-dossier-app>)"
  exit 1
fi

if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
  echo "Usage: sudo $0 <votre-nom-de-domaine> <nom-du-dossier-app>"
  echo "Exemple: sudo $0 mon-app.fr mon-projet"
  exit 1
fi

DOMAIN="$1"
APP_NAME="$2"
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
APP_DIR="/var/www/$APP_NAME"
APP_PORT=3000
SKIP_COPY=false

echo "================================================================="
echo "   Assistant de deploiement : Node.js + Caddy + Coraza WAF"
echo "================================================================="
echo ""

# --- ETAPE 1 : Verification DNS interactive ---
echo "[Etape 1/3 - Verification Reseau & DNS]"
echo "Pour que Caddy genere automatiquement votre certificat HTTPS (SSL),"
echo "votre nom de domaine ($DOMAIN) DOIT deja pointer vers l'IP publique de ce serveur"
echo "(enregistrement DNS de type A/AAAA) et les ports 80/443 doivent etre ouverts."
read -p "-> Avez-vous deja configure votre enregistrement DNS pour $DOMAIN ? (y/n) : " DNS_READY

if [[ ! "$DNS_READY" =~ ^[Yy]$ ]]; then
  echo ""
  echo "[PAUSE] Deploiement mis en pause."
  echo "=> Action requise : Allez chez votre hebergeur de domaine (OVH, Cloudflare, Namecheap...),"
  echo "   creez un enregistrement A pointant '$DOMAIN' vers l'IP de ce serveur, puis relancez ce script."
  exit 0
fi

# --- ETAPE 2 : Choix entre Web App existante ou App de demo ---
echo ""
echo "[Etape 2/3 - Configuration de votre application Node.js]"
read -p "-> Avez-vous deja votre propre application web Node.js prete a etre deployee ? (y/n) : " HAS_APP

if [[ "$HAS_APP" =~ ^[Yy]$ ]]; then
  echo ""
  echo "[INFO] Parfait ! Voici comment nous allons proceder :"
  read -p "   1. Chemin complet du dossier contenant votre code actuel (ex: /home/$REAL_USER/mon-site) : " EXISTING_PATH
  
  if [ ! -d "$EXISTING_PATH" ]; then
    echo "[ERREUR] Le dossier '$EXISTING_PATH' n'existe pas. Verifiez le chemin et relancez."
    exit 1
  fi

  read -p "   2. Nom de votre fichier de demarrage principal (ex: server.js, app.js, index.js) : " ENTRY_FILE
  if [ ! -f "$EXISTING_PATH/$ENTRY_FILE" ]; then
    echo "[ERREUR] Le fichier '$EXISTING_PATH/$ENTRY_FILE' est introuvable."
    exit 1
  fi

  read -p "   3. Sur quel port ecoute votre application Node.js ? (defaut: 3000) : " USER_PORT
  APP_PORT="${USER_PORT:-3000}"

  # Verification des chemins pour eviter l'ecrasement ou l'auto-copie
  REAL_SRC=$(realpath "$EXISTING_PATH")
  REAL_DST=$(realpath -m "$APP_DIR")

  if [ "$REAL_SRC" = "$REAL_DST" ]; then
    echo "[INFO] Votre code se trouve deja dans la destination ($APP_DIR)."
    echo "       Aucune copie ne sera effectuee, l'application sera configuree directement sur place."
    SKIP_COPY=true
  elif [ -d "$APP_DIR" ] && [ -n "$(ls -A "$APP_DIR" 2>/dev/null)" ]; then
    echo ""
    echo "[ATTENTION] Le dossier cible '$APP_DIR' existe deja et n'est pas vide !"
    read -p "-> Voulez-vous sauvegarder l'ancien dossier et le remplacer par votre application ? (y/n) : " OVERWRITE_OK
    if [[ ! "$OVERWRITE_OK" =~ ^[Yy]$ ]]; then
      echo "[ANNULE] Deploiement annule pour proteger vos fichiers existants."
      echo "         Relancez le script avec un autre <nom-du-dossier-app> (ex: ${APP_NAME}-v2)."
      exit 0
    fi
    BACKUP_DIR="${APP_DIR}.bak.$(date +%Y%m%d_%H%M%S)"
    echo "[INFO] Sauvegarde de l'ancien dossier vers $BACKUP_DIR..."
    mv "$APP_DIR" "$BACKUP_DIR"
  fi
else
  # Verification si le dossier cible existe deja avant de generer l'app de demo
  if [ -d "$APP_DIR" ] && [ -n "$(ls -A "$APP_DIR" 2>/dev/null)" ]; then
    echo ""
    echo "[ATTENTION] Le dossier cible '$APP_DIR' existe deja et n'est pas vide !"
    read -p "-> Voulez-vous sauvegarder l'ancien dossier et installer l'app de demo ? (y/n) : " OVERWRITE_OK
    if [[ ! "$OVERWRITE_OK" =~ ^[Yy]$ ]]; then
      echo "[ANNULE] Deploiement annule pour proteger vos fichiers existants."
      echo "         Relancez le script avec un autre <nom-du-dossier-app>."
      exit 0
    fi
    BACKUP_DIR="${APP_DIR}.bak.$(date +%Y%m%d_%H%M%S)"
    echo "[INFO] Sauvegarde de l'ancien dossier vers $BACKUP_DIR..."
    mv "$APP_DIR" "$BACKUP_DIR"
  fi

  echo ""
  echo "[INFO] Pas de souci ! Une application de demonstration Express sera creee automatiquement"
  echo "       dans $APP_DIR sur le port $APP_PORT pour tester votre installation."
fi

# --- ETAPE 3 : Choix du mode WAF (Observation vs Blocage) ---
echo ""
echo "[Etape 3/3 - Mode de protection du pare-feu Coraza WAF]"
echo "Sur une vraie application, activer le blocage immediat peut bloquer des utilisateurs"
echo "legitimes (faux positifs). Il est recommande de demarrer en mode 'Observation'."
read -p "-> Voulez-vous demarrer en mode Observation securise (recommande) ? (y = Observation / n = Blocage strict) : " WAF_SAFE

if [[ "$WAF_SAFE" =~ ^[Yy]$ ]]; then
  WAF_ENGINE_MODE="DetectionOnly"
  echo "[OK] Mode selectionne : Observation (DetectionOnly) - Les attaques sont enregistrees sans bloquer le trafic."
else
  WAF_ENGINE_MODE="On"
  echo "[!] Mode selectionne : Blocage strict (On) - Toute requete suspecte recevra une erreur 403."
fi

echo ""
echo ">> Lancement de l'installation complete dans 3 secondes..."
sleep 3

# =================================================================
# EXECUTION DE L'INSTALLATION
# =================================================================

echo "[1/6] Configuration du pare-feu UFW"
apt-get update && apt-get install -y ufw curl git build-essential debian-keyring debian-archive-keyring apt-transport-https golang-go iproute2
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable

echo "[2/6] Installation de Node.js 20 LTS, PM2 et mise en place de l'app dans $APP_DIR"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
npm install -g pm2

mkdir -p "$APP_DIR"

if [[ "$HAS_APP" =~ ^[Yy]$ ]]; then
  if [ "$SKIP_COPY" = false ]; then
    echo "[INFO] Copie de votre application vers $APP_DIR..."
    cp -a "$EXISTING_PATH/." "$APP_DIR/"
  else
    echo "[INFO] Utilisation directe des fichiers presents dans $APP_DIR..."
  fi
  chown -R "$REAL_USER":"$REAL_USER" "$APP_DIR"

  # Creation d'un fichier ecosystem PM2 qui force HOST=127.0.0.1 et PORT=$APP_PORT
  cat << EOF > "$APP_DIR/ecosystem.config.js"
module.exports = {
  apps: [{
    name: '${APP_NAME}-node',
    script: './$ENTRY_FILE',
    env: {
      NODE_ENV: 'production',
      HOST: '127.0.0.1',
      HOSTNAME: '127.0.0.1',
      PORT: $APP_PORT
    }
  }]
};
EOF
  chown "$REAL_USER":"$REAL_USER" "$APP_DIR/ecosystem.config.js"

  su - "$REAL_USER" -c "
    cd '$APP_DIR'
    if [ -f package.json ]; then
      npm install --production
    fi
    pm2 delete '${APP_NAME}-node' 2>/dev/null || true
    pm2 start ecosystem.config.js
    pm2 save
  "

  # Verification de securite : s'assurer que le port n'ecoute pas sur 0.0.0.0 (*)
  sleep 2
  if ss -tulnp | grep -E ":$APP_PORT\b" | grep -qE "0\.0\.0\.0:|\[::\]:|\*:"; then
    echo ""
    echo "[ALERTE SECURITE] Votre code '$ENTRY_FILE' force l'ecoute sur toutes les interfaces (0.0.0.0) !"
    echo "                  Modifiez votre ligne app.listen(...) pour mettre : app.listen($APP_PORT, '127.0.0.1')"
    echo "                  (Note: UFW bloque deja le port $APP_PORT depuis l'exterieur, mais corriger le code est recommande)."
    echo ""
  else
    echo "[OK] Verification reseau : L'application ecoute bien uniquement en local (127.0.0.1:$APP_PORT)."
  fi
else
  chown -R "$REAL_USER":"$REAL_USER" "$APP_DIR"
  su - "$REAL_USER" -c "
    cd '$APP_DIR'
    npm init -y
    npm install express
    cat << 'EOF' > server.js
const express = require('express');
const app = express();
const PORT = $APP_PORT;

app.set('trust proxy', 1);
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

app.get('/', (req, res) => {
  res.send(\`
    <h1>Application Node.js ($APP_NAME) en ligne !</h1>
    <p>Connexion chiffree via Caddy et protegee par Coraza WAF.</p>
    <p>Votre adresse IP detectee : \${req.ip}</p>
  \`);
});

app.post('/api/login', (req, res) => {
  res.json({ status: 'ok', message: 'Requete propre recu par Node.js', user: req.body.username });
});

app.listen(PORT, '127.0.0.1', () => {
  console.log(\`Serveur Node.js actif en interne sur http://127.0.0.1:\${PORT}\`);
});
EOF
    pm2 delete '${APP_NAME}-node' 2>/dev/null || true
    pm2 start server.js --name '${APP_NAME}-node'
    pm2 save
  "
fi

env PATH=$PATH:/usr/bin pm2 startup systemd -u "$REAL_USER" --hp "$REAL_HOME"

echo "[3/6] Compilation de Caddy + Coraza WAF via xcaddy"
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/xcaddy/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-xcaddy-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/xcaddy/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-xcaddy.list
apt-get update && apt-get install -y xcaddy

cd /tmp
xcaddy build --with github.com/corazawaf/coraza-caddy/v2
mv /tmp/caddy /usr/bin/caddy
chmod +x /usr/bin/caddy

echo "[4/6] Installation des regles OWASP CRS et configuration Coraza"
groupadd --system caddy || true
useradd --system --gid caddy --create-home --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy || true
mkdir -p /etc/caddy /var/log/caddy

if [ ! -d "/etc/caddy/coreruleset" ]; then
  git clone https://github.com/coreruleset/coreruleset /etc/caddy/coreruleset
fi
cp /etc/caddy/coreruleset/crs-setup.conf.example /etc/caddy/coreruleset/crs-setup.conf

curl -sSL -o /etc/caddy/coraza.conf https://raw.githubusercontent.com/corazawaf/coraza/main/coraza.conf-recommended
sed -i "s/SecRuleEngine DetectionOnly/SecRuleEngine $WAF_ENGINE_MODE/" /etc/caddy/coraza.conf
chown -R caddy:caddy /etc/caddy /var/lib/caddy /var/log/caddy

echo "[5/6] Generation du Caddyfile"
cat << EOF > /etc/caddy/Caddyfile
{
    order coraza_waf first
}

$DOMAIN {
    coraza_waf {
        include /etc/caddy/coraza.conf
        include /etc/caddy/coreruleset/crs-setup.conf
        include /etc/caddy/coreruleset/rules/*.conf
        directives \`
            SecRequestBodyAccess On
            SecRule REQUEST_HEADERS:Content-Type "^application/json" "id:200001,phase:1,t:none,t:lowercase,pass,nolog,ctl:requestBodyProcessor=JSON"
            SecAuditEngine RelevantOnly
            SecAuditLog /var/log/caddy/coraza_audit.log
            SecAuditLogParts ABIJDEFHZ
        \`
    }

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
    }

    encode zstd gzip
    reverse_proxy 127.0.0.1:$APP_PORT
}
EOF
chown caddy:caddy /etc/caddy/Caddyfile

echo "[6/6] Creation et activation du service systemd"
cat << 'EOF' > /etc/systemd/system/caddy.service
[Unit]
Description=Caddy Reverse Proxy avec Coraza WAF
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

caddy validate --config /etc/caddy/Caddyfile
systemctl daemon-reload
systemctl enable --now caddy

echo ""
echo "================================================================="
echo "[OK] Deploiement termine avec succes !"
echo "================================================================="
echo " * URL publique           : https://$DOMAIN"
echo " * Dossier application    : $APP_DIR"
echo " * Mode actuel WAF Coraza : $WAF_ENGINE_MODE"
echo " * Logs d'alertes WAF     : /var/log/caddy/coraza_audit.log"
echo ""
if [ "$WAF_ENGINE_MODE" = "DetectionOnly" ]; then
  echo "[CONSEIL] Testez votre site pendant 24-48h, verifiez les logs ci-dessus,"
  echo "          puis passez en mode blocage strict avec la commande :"
  echo "          sudo sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' /etc/caddy/coraza.conf && sudo systemctl reload caddy"
fi