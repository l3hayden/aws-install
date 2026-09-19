#!/usr/bin/env bash
#
# Provision a Debian + Apache + WordPress host: optionally install the whole
# stack on a bare instance, then rewrites, TLS, renewal, the WordPress-side
# URL settings and the standard plugins.
#
# Idempotent — safe to re-run. Every step checks its own state first and says
# what it did or why it skipped.
#
#   sudo ./provision-wordpress-tls.sh --domain example.co.nz --email you@example.com --install
#   sudo ./provision-wordpress-tls.sh --domain example.co.nz --email you@example.com
#   sudo ./provision-wordpress-tls.sh --domain example.co.nz --email you@example.com --dry-run
#   sudo ./provision-wordpress-tls.sh --domain example.co.nz --htaccess     # one step only
#
# See README.md for what each step is for and the failure it prevents.

set -euo pipefail

DOMAIN=""
EMAIL=""
DOCROOT="/var/www/html"
WITH_WWW=1
BEHIND_PROXY=0
DRY_RUN=0
SKIP_TLS=0
ADMIN_USER="user"
ADMIN_EMAIL=""
BREAKDANCE_ZIP=""

# Plugins every site gets, by wordpress.org slug. Breakdance is not on
# wordpress.org and needs a licensed download, so it comes from --breakdance.
WP_PLUGINS=(all-in-one-wp-migration autodescription smtp2go)

# Step selection. None given = every step except --install and --plugins.
DO_INSTALL=0
DO_PLUGINS=0
DO_HTACCESS=0
DO_CERTBOT=0
DO_RENEWAL=0
DO_WP=0
DO_VERIFY=0
REPORT_ONLY=0

usage() {
	cat <<'USAGE'
Usage: provision-wordpress-tls.sh --domain DOMAIN --email EMAIL [options]

Required:
  --domain DOMAIN     Apex domain, e.g. example.co.nz (no scheme, no www)
  --email EMAIL       Let's Encrypt registration + expiry notices

Options:
  --docroot PATH      WordPress document root      (default: /var/www/html)
  --no-www            Request a cert for the apex only (default: apex + www)
  --behind-proxy      Site sits behind Cloudflare / an ELB that terminates TLS.
                      Adds the X-Forwarded-Proto handling to wp-config.php.
  --skip-tls          Do the rewrite + WordPress steps only, no certbot
  --dry-run           Print what would change, touch nothing
  --admin-user NAME   WordPress admin username for --install (default: user)
  --admin-email EMAIL WordPress admin email for --install    (default: --email)
  --breakdance ZIP    Breakdance plugin zip, a local path or URL. Download it
                      from breakdance.com (needs your login).
  -h, --help          This message

Steps (pick any; none given = htaccess certbot renewal wp-urls verify):
  --install           Bare Debian 13 instance: Apache, PHP-FPM, MariaDB,
                      wp-cli, latest WordPress with no bundled plugins,
                      credentials to ~/wordpress_credentials. On its own it
                      also runs every other step, plugins included.
  --htaccess          Check/build rewrite prerequisites: mod_rewrite,
                      AllowOverride All, and the WordPress .htaccess
  --certbot           Install certbot + apache plugin, obtain/expand the cert
  --renewal           Check the renewal timer, install the apache reload hook
  --wp-urls           WP_HOME/WP_SITEURL in wp-config.php, home/siteurl,
                      FORCE_SSL_ADMIN, proxy HTTPS detection
  --plugins           Install + activate the standard plugins
  --verify            curl / and /wp-json/ on every name
  --report            Run no steps, just print the status report

A status report of the whole host is always printed at the end. The exit
status is 1 if any report line is FAIL (except under --dry-run).
USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--domain)       DOMAIN="$2"; shift 2 ;;
		--email)        EMAIL="$2"; shift 2 ;;
		--docroot)      DOCROOT="$2"; shift 2 ;;
		--no-www)       WITH_WWW=0; shift ;;
		--behind-proxy) BEHIND_PROXY=1; shift ;;
		--skip-tls)     SKIP_TLS=1; shift ;;
		--dry-run)      DRY_RUN=1; shift ;;
		--admin-user)   ADMIN_USER="$2"; shift 2 ;;
		--admin-email)  ADMIN_EMAIL="$2"; shift 2 ;;
		--breakdance)   BREAKDANCE_ZIP="$2"; shift 2 ;;
		--install)      DO_INSTALL=1; shift ;;
		--plugins)      DO_PLUGINS=1; shift ;;
		--htaccess)     DO_HTACCESS=1; shift ;;
		--certbot)      DO_CERTBOT=1; shift ;;
		--renewal)      DO_RENEWAL=1; shift ;;
		--wp-urls)      DO_WP=1; shift ;;
		--verify)       DO_VERIFY=1; shift ;;
		--report)       REPORT_ONLY=1; shift ;;
		-h|--help)      usage; exit 0 ;;
		*)              echo "Unknown option: $1" >&2; usage; exit 1 ;;
	esac
done

if (( SKIP_TLS && (DO_CERTBOT || DO_RENEWAL) )); then
	echo "--skip-tls conflicts with --certbot / --renewal" >&2; exit 1
fi
ANY_STEP=$(( DO_INSTALL || DO_PLUGINS || DO_HTACCESS || DO_CERTBOT || DO_RENEWAL || DO_WP || DO_VERIFY ))
if (( REPORT_ONLY && ANY_STEP )); then
	echo "--report runs no steps; drop it or drop the step flags" >&2; exit 1
fi
# --install on its own is a fresh box: it wants everything.
if (( DO_INSTALL && ! (DO_PLUGINS || DO_HTACCESS || DO_CERTBOT || DO_RENEWAL || DO_WP || DO_VERIFY) )); then
	DO_PLUGINS=1
	ANY_STEP=0
fi
if (( ! REPORT_ONLY && ! ANY_STEP )); then
	DO_HTACCESS=1; DO_WP=1; DO_VERIFY=1
	(( SKIP_TLS )) || { DO_CERTBOT=1; DO_RENEWAL=1; }
fi

SCHEME=$( (( SKIP_TLS )) && echo http || echo https )
CANONICAL="$SCHEME://$( (( WITH_WWW )) && echo "www.$DOMAIN" || echo "$DOMAIN" )"

# ---------------------------------------------------------------- helpers ---

C_OK=$'\033[32m'; C_SKIP=$'\033[90m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_OFF=$'\033[0m'

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$C_OK"   "$C_OFF" "$*"; }
skip() { printf '    %s·%s %s\n' "$C_SKIP" "$C_OFF" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
die()  { printf '    %s✗%s %s\n' "$C_ERR"  "$C_OFF" "$*" >&2; exit 1; }

run() {
	if (( DRY_RUN )); then
		printf '    %swould run:%s %s\n' "$C_SKIP" "$C_OFF" "$*"
	else
		"$@"
	fi
}

# Write $2 to file $1 only if the content differs. Backs up whatever was there.
write_file() {
	local path="$1" content="$2"
	if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$content" ]]; then
		skip "$path already correct"
		return
	fi
	if [[ -f "$path" ]]; then
		local backup="${path}.bak.$(date +%Y%m%d%H%M%S)"
		if (( DRY_RUN )); then
			printf '    %swould back up:%s %s -> %s\n' "$C_SKIP" "$C_OFF" "$path" "$backup"
		else
			cp -a "$path" "$backup"
			warn "existing file backed up to $backup"
		fi
	fi
	if (( DRY_RUN )); then
		printf '    %swould write:%s %s (%s bytes)\n' "$C_SKIP" "$C_OFF" "$path" "${#content}"
	else
		printf '%s\n' "$content" > "$path"
		ok "wrote $path"
	fi
}

# ------------------------------------------------------------- preflight ----

step "Preflight"

[[ -n "$DOMAIN" ]] || { usage; die "--domain is required"; }
if (( DO_CERTBOT )); then
	[[ -n "$EMAIL" ]] || { usage; die "--email is required for the certbot step"; }
fi
[[ $EUID -eq 0 ]] || die "run this with sudo"

if (( DO_INSTALL )); then
	ADMIN_EMAIL="${ADMIN_EMAIL:-$EMAIL}"
	[[ -n "$ADMIN_EMAIL" ]] || { usage; die "--install needs --email or --admin-email for the WordPress admin"; }
	# Debian 13 is the release whose own repos carry a current PHP (8.4) and
	# certbot's apache plugin. Older releases need third-party PHP repos.
	OS_ID=$(. /etc/os-release && echo "${ID:-}")
	OS_VER=$(. /etc/os-release && echo "${VERSION_ID:-}")
	[[ "$OS_ID" == debian && "$OS_VER" == 13 ]] \
		|| die "--install targets Debian 13; this is $(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")"
	ok "os          : Debian $OS_VER"
else
	command -v apache2ctl >/dev/null 2>&1 || (( ! (DO_HTACCESS || DO_CERTBOT || DO_RENEWAL) )) || die "apache2 not found — this script targets Debian/Ubuntu Apache (use --install on a bare instance)"
	[[ -d "$DOCROOT" ]] || die "docroot $DOCROOT does not exist"
	[[ -f "$DOCROOT/wp-config.php" || -f "$DOCROOT/wp-load.php" ]] \
		|| warn "no wp-config.php in $DOCROOT — continuing, but the WordPress steps will be skipped"
fi

ok "domain      : $DOMAIN"
(( WITH_WWW )) && ok "www variant : www.$DOMAIN" || skip "www variant : not requested"
ok "docroot     : $DOCROOT"
STEPS=""
(( DO_INSTALL ))  && STEPS+="install "
(( DO_HTACCESS )) && STEPS+="htaccess "
(( DO_CERTBOT ))  && STEPS+="certbot "
(( DO_RENEWAL ))  && STEPS+="renewal "
(( DO_WP ))       && STEPS+="wp-urls "
(( DO_PLUGINS ))  && STEPS+="plugins "
(( DO_VERIFY ))   && STEPS+="verify"
ok "steps       : $STEPS"
(( DRY_RUN ))  && warn "DRY RUN — nothing will be modified"

# DNS has to resolve before certbot's HTTP-01 challenge can possibly work.
if (( DO_CERTBOT )); then
	for host in "$DOMAIN" $( (( WITH_WWW )) && echo "www.$DOMAIN" ); do
		if getent hosts "$host" >/dev/null 2>&1; then
			ok "DNS resolves: $host -> $(getent hosts "$host" | awk '{print $1}' | head -1)"
		else
			die "DNS does not resolve for $host — certbot will fail. Fix DNS first."
		fi
	done
fi

# ------------------------------------------------------------ 0. install ----
#
# A bare Debian 13 instance to a running WordPress with nothing extra: no
# phpMyAdmin, no bundled plugins. Passwords are generated on the host and only
# ever written to wp-config.php and the credentials file — never to the repo.

# Credentials land in the home of whoever ran sudo (admin on Lightsail).
CREDS_USER="${SUDO_USER:-root}"
CREDS_HOME=$(getent passwd "$CREDS_USER" | cut -d: -f6 || true)
CREDS_FILE="${CREDS_HOME:-/root}/wordpress_credentials"

# 24 alphanumerics: safe unquoted in SQL and shell, ~140 bits.
gen_pass() { openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-24; }

if (( ! DO_INSTALL )); then
	step "0. Install stack + WordPress — not selected"
elif (( DRY_RUN )); then
	step "0. Install stack + WordPress"
	skip "dry run — would:"
	skip "  add a 1G swap file if RAM < 2G and there is no swap"
	skip "  apt install apache2, php-fpm + WordPress extensions, mariadb-server"
	skip "  switch Apache to PHP-FPM, write a vhost for $DOMAIN"
	skip "  install wp-cli, download the latest WordPress into $DOCROOT"
	skip "  create the database + user, wp-config.php, admin '$ADMIN_USER'"
	skip "  delete Akismet, Hello Dolly and inactive themes"
	skip "  write credentials to $CREDS_FILE"
else
step "0. Install stack + WordPress"

export DEBIAN_FRONTEND=noninteractive

# MariaDB + PHP-FPM on a 512M/1G Lightsail plan get OOM-killed without swap.
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if [[ -n "$(swapon --noheadings --show=NAME 2>/dev/null)" ]]; then
	skip "swap already configured"
elif (( MEM_MB >= 2048 )); then
	skip "${MEM_MB}M RAM — no swap needed"
elif { [[ -f /swapfile ]] || { fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap -q /swapfile; }; } \
	&& swapon /swapfile 2>/dev/null; then
	grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
	ok "added 1G swap at /swapfile (${MEM_MB}M RAM)"
else
	warn "could not enable swap — ${MEM_MB}M RAM may not be enough for MariaDB + PHP"
fi

# Only what WordPress uses. php-fpm rather than mod_php: it runs under the
# event MPM, which is the Apache default on Debian.
PKGS=(apache2 mariadb-server php-fpm php-cli php-mysql php-curl php-gd php-intl
	php-mbstring php-xml php-zip curl unzip ca-certificates openssl)
MISSING_PKGS=()
for p in "${PKGS[@]}"; do
	dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || MISSING_PKGS+=("$p")
done
if (( ${#MISSING_PKGS[@]} )); then
	apt-get update -qq
	apt-get install -y -qq --no-install-recommends "${MISSING_PKGS[@]}" >/dev/null
	ok "installed ${MISSING_PKGS[*]}"
else
	skip "packages already installed"
fi
# opcache ships as its own package; --no-install-recommends leaves it out.
PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
if dpkg-query -W -f='${Status}' "php$PHP_VER-opcache" 2>/dev/null | grep -q "install ok installed"; then
	skip "php$PHP_VER-opcache already installed"
else
	apt-get install -y -qq --no-install-recommends "php$PHP_VER-opcache" >/dev/null
	ok "installed php$PHP_VER-opcache"
fi
ok "PHP $PHP_VER"

# Big enough for All-in-One WP Migration imports and Breakdance's editor.
write_file "/etc/php/$PHP_VER/fpm/conf.d/99-wordpress.ini" "; Written by provision-wordpress-tls.sh
upload_max_filesize = 512M
post_max_size = 512M
memory_limit = 256M
max_execution_time = 300
max_input_time = 300
max_input_vars = 5000"

a2dismod -q mpm_prefork >/dev/null 2>&1 || true
a2enmod -q mpm_event proxy_fcgi setenvif rewrite >/dev/null
a2enconf -q "php$PHP_VER-fpm" >/dev/null
ok "Apache → php$PHP_VER-fpm (mpm_event, proxy_fcgi)"

# certbot --apache needs a vhost whose ServerName matches, or it can't pick
# one non-interactively.
VHOST="/etc/apache2/sites-available/$DOMAIN.conf"
write_file "$VHOST" "<VirtualHost *:80>
	ServerName $DOMAIN$( (( WITH_WWW )) && printf '\n\tServerAlias www.%s' "$DOMAIN" )
	DocumentRoot $DOCROOT
	ErrorLog \${APACHE_LOG_DIR}/$DOMAIN-error.log
	CustomLog \${APACHE_LOG_DIR}/$DOMAIN-access.log combined
</VirtualHost>"
a2ensite -q "$DOMAIN" >/dev/null
a2dissite -q 000-default >/dev/null 2>&1 || true

systemctl enable --now mariadb >/dev/null 2>&1 || true
systemctl restart "php$PHP_VER-fpm"
apache2ctl configtest >/dev/null 2>&1 || die "Apache config test failed — run: apache2ctl configtest"
systemctl reload apache2 || systemctl restart apache2
ok "services running"

if command -v wp >/dev/null 2>&1; then
	skip "wp-cli already installed"
else
	curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
	chmod +x /usr/local/bin/wp
	ok "installed $(wp --allow-root --version)"
fi

WP="wp --path=$DOCROOT --allow-root"

if $WP core is-installed 2>/dev/null; then
	skip "WordPress already installed in $DOCROOT — leaving it alone"
else
	if [[ ! -f "$DOCROOT/wp-load.php" ]]; then
		# Debian's placeholder page is the only thing allowed to be in the way.
		if [[ -f "$DOCROOT/index.html" ]] && grep -q "Apache2 Debian Default Page" "$DOCROOT/index.html"; then
			rm -f "$DOCROOT/index.html"
		fi
		[[ -z "$(find "$DOCROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
			|| die "$DOCROOT is not empty and has no WordPress in it — refusing to install over it"
		$WP core download --quiet
		ok "downloaded WordPress $($WP core version)"
	fi

	DB_NAME=wordpress
	DB_USER=wordpress
	DB_PASS=$(gen_pass)
	ADMIN_PASS=$(gen_pass)
	mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
	ok "database '$DB_NAME' and user '$DB_USER'"

	$WP config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" \
		--dbhost=localhost --dbcharset=utf8mb4 --force --quiet
	$WP core install --url="$CANONICAL" --title="$DOMAIN" --admin_user="$ADMIN_USER" \
		--admin_password="$ADMIN_PASS" --admin_email="$ADMIN_EMAIL" --skip-email >/dev/null
	ok "installed WordPress at $CANONICAL, admin '$ADMIN_USER'"

	# Ships with core; not wanted on any site.
	for p in akismet hello; do
		$WP plugin is-installed "$p" 2>/dev/null && $WP plugin delete "$p" --quiet
	done
	INACTIVE_THEMES=$($WP theme list --status=inactive --field=name 2>/dev/null || true)
	[[ -n "$INACTIVE_THEMES" ]] && $WP theme delete $INACTIVE_THEMES --quiet
	ok "removed bundled plugins and inactive themes"

	# Pretty permalinks from day one; the .htaccess step makes them route.
	$WP rewrite structure '/%postname%/' --quiet

	umask_old=$(umask); umask 077
	cat > "$CREDS_FILE" <<CREDS
WordPress credentials for $DOMAIN
Generated $(date -Is) by provision-wordpress-tls.sh.
Move these into your password manager, then delete this file.

Site URL        : $CANONICAL
Admin URL       : $CANONICAL/wp-admin/
Admin user      : $ADMIN_USER
Admin password  : $ADMIN_PASS
Admin email     : $ADMIN_EMAIL

Database        : $DB_NAME
DB user         : $DB_USER
DB password     : $DB_PASS
DB host         : localhost
CREDS
	umask "$umask_old"
	chown "$CREDS_USER": "$CREDS_FILE"
	ok "credentials written to $CREDS_FILE (mode 600)"
fi

chown -R www-data:www-data "$DOCROOT"
[[ -f "$DOCROOT/wp-config.php" ]] && chmod 640 "$DOCROOT/wp-config.php"
fi # DO_INSTALL

# ----------------------------------------------------------- 1. rewrites ----
#
# The single most common cause of "/wp-json/ 404s and every pretty permalink
# is broken". A fresh WordPress uses plain permalinks and needs none of this,
# so the fault stays invisible until a database import brings a real
# permalink_structure with it.

if (( ! DO_HTACCESS )); then
	step "1. Apache rewrite prerequisites — not selected"
else
step "1. Apache rewrite prerequisites"

if apache2ctl -M 2>/dev/null | grep -q rewrite_module; then
	skip "mod_rewrite already enabled"
else
	run a2enmod rewrite
	ok "enabled mod_rewrite"
	NEEDS_RELOAD=1
fi

# Debian ships AllowOverride None for /var/www/, which makes .htaccess inert.
APACHE_CONF="/etc/apache2/apache2.conf"
if grep -qE "^\s*AllowOverride\s+All" "$APACHE_CONF"; then
	skip "AllowOverride All already set in $APACHE_CONF"
else
	if (( DRY_RUN )); then
		printf '    %swould set:%s AllowOverride All for <Directory /var/www/> in %s\n' "$C_SKIP" "$C_OFF" "$APACHE_CONF"
	else
		cp -a "$APACHE_CONF" "${APACHE_CONF}.bak.$(date +%Y%m%d%H%M%S)"
		# Only inside the <Directory /var/www/> block — leave / and others alone.
		sed -i '\#<Directory /var/www/>#,\#</Directory># s/AllowOverride None/AllowOverride All/' "$APACHE_CONF"
		if grep -qE "^\s*AllowOverride\s+All" "$APACHE_CONF"; then
			ok "set AllowOverride All for <Directory /var/www/>"
			NEEDS_RELOAD=1
		else
			warn "could not set AllowOverride automatically — check $APACHE_CONF by hand"
		fi
	fi
fi

# The standard WordPress block. The HTTP_AUTHORIZATION line is not decoration:
# without it PHP never sees the Authorization header, and application passwords
# fail on every REST request (which breaks MCP connectors, WP-CLI over HTTP,
# and any headless client).
HTACCESS_CONTENT='# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress'

if [[ -f "$DOCROOT/.htaccess" ]] && grep -q "BEGIN WordPress" "$DOCROOT/.htaccess"; then
	if grep -q "HTTP_AUTHORIZATION" "$DOCROOT/.htaccess"; then
		skip ".htaccess present with the WordPress block and HTTP_AUTHORIZATION"
	else
		warn ".htaccess has the WordPress block but no HTTP_AUTHORIZATION line"
		warn "  application passwords over REST will fail — add it by hand, or"
		warn "  move the file aside and re-run to get the full block"
	fi
else
	write_file "$DOCROOT/.htaccess" "$HTACCESS_CONTENT"
	if (( ! DRY_RUN )); then
		chown www-data:www-data "$DOCROOT/.htaccess"
		chmod 644 "$DOCROOT/.htaccess"
	fi
fi

if [[ -n "${NEEDS_RELOAD:-}" ]]; then
	run apache2ctl configtest
	run systemctl reload apache2
	ok "apache reloaded"
fi
fi # DO_HTACCESS

# ---------------------------------------------------------------- 2. TLS ----

if (( ! DO_CERTBOT )); then
	step "2. certbot — not selected"
else
	step "2. certbot"

	if command -v certbot >/dev/null 2>&1; then
		skip "certbot already installed ($(command -v certbot))"
	else
		run apt-get update -qq
		run apt-get install -y certbot
		ok "installed certbot"
	fi

	# The Apache plugin is a SEPARATE package on Debian/Ubuntu. Without it
	# certbot fails with "The apache plugin does not appear to be installed".
	# (A snap-installed certbot bundles it — hence the branch.)
	if certbot plugins 2>/dev/null | grep -q apache; then
		skip "certbot apache plugin available"
	elif [[ "$(command -v certbot)" == /snap/* ]]; then
		warn "snap certbot without the apache plugin — try: snap install --classic certbot"
	else
		run apt-get install -y python3-certbot-apache
		ok "installed python3-certbot-apache"
	fi

	CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
	CERT_ARGS=(--apache --non-interactive --agree-tos -m "$EMAIL" --redirect -d "$DOMAIN")
	(( WITH_WWW )) && CERT_ARGS+=(-d "www.$DOMAIN")

	if [[ -d "$CERT_DIR" ]]; then
		# A cert exists — check it actually covers every name we want. The
		# failure worth catching: a www-only cert on a host whose HTTP vhost
		# redirects the apex to the apex, so anyone typing the bare domain gets
		# a TLS warning and nothing in normal monitoring reports it.
		EXISTING_SANS=$(openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -ext subjectAltName 2>/dev/null \
			| tr ',' '\n' | sed -n 's/.*DNS://p' | tr -d ' ' | sort | tr '\n' ' ')
		ok "existing cert covers: $EXISTING_SANS"

		MISSING=""
		for host in "$DOMAIN" $( (( WITH_WWW )) && echo "www.$DOMAIN" ); do
			grep -qw "$host" <<<"$EXISTING_SANS" || MISSING="$MISSING $host"
		done

		if [[ -n "$MISSING" ]]; then
			warn "cert is MISSING:$MISSING — reissuing to cover all names"
			run certbot "${CERT_ARGS[@]}" --expand
		else
			skip "cert already covers every requested name"
		fi
	else
		run certbot "${CERT_ARGS[@]}"
		ok "obtained certificate"
	fi
fi

# ------------------------------------------------------------ 3. renewal ----

if (( ! DO_RENEWAL )); then
	step "3. Renewal — not selected"
else
	step "3. Renewal automation"

	# certbot installs its own scheduler. Do NOT add a cron on top of it: two
	# schedulers contend for the same lock. We only verify it is there and add
	# the reload hook, which is the piece that is genuinely missing by default.
	if systemctl list-timers --all 2>/dev/null | grep -qi certbot; then
		ok "systemd timer present: $(systemctl list-timers --all | grep -i certbot | awk '{print $NF}' | head -1)"
	elif [[ -f /etc/cron.d/certbot ]]; then
		ok "cron job present: /etc/cron.d/certbot"
	else
		warn "no renewal timer or cron found — certificates will EXPIRE"
		warn "  apt:  systemctl enable --now certbot.timer"
		warn "  snap: systemctl enable --now snap.certbot.renew.timer"
	fi

	# Apache keeps serving the old certificate from memory after a renewal
	# unless something reloads it. This is the classic silent failure: renewal
	# succeeds, nothing reloads, the site serves an expired cert for weeks.
	HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
	HOOK_CONTENT='#!/bin/sh
# Reload Apache after a successful renewal so it picks up the new certificate.
systemctl reload apache2'

	run mkdir -p "$HOOK_DIR"
	write_file "$HOOK_DIR/reload-apache.sh" "$HOOK_CONTENT"
	(( DRY_RUN )) || chmod +x "$HOOK_DIR/reload-apache.sh"

	echo
	warn "verify renewal actually works — this is the step people skip:"
	warn "    sudo certbot renew --dry-run"
fi

# -------------------------------------------------- 4. WordPress settings ---

if (( ! DO_WP )); then
	step "4. WordPress URL configuration — not selected"
else
step "4. WordPress URL configuration"

if ! command -v wp >/dev/null 2>&1; then
	warn "wp-cli not installed — skipping. Install it with:"
	warn "    curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
	warn "    chmod +x /usr/local/bin/wp"
elif [[ ! -f "$DOCROOT/wp-config.php" ]]; then
	warn "no wp-config.php in $DOCROOT — skipping"
else
	WP="wp --path=$DOCROOT --allow-root"

	CURRENT_HOME=$($WP option get home 2>/dev/null || echo "")
	if [[ "$CURRENT_HOME" == "$CANONICAL" ]]; then
		skip "home/siteurl already $CANONICAL"
	else
		warn "home is currently '$CURRENT_HOME', canonical is '$CANONICAL'"
		run $WP option update home "$CANONICAL"
		run $WP option update siteurl "$CANONICAL"
		ok "set home and siteurl to $CANONICAL"
		warn "existing content may still hold the old URL — see README, 'After a migration'"
	fi

	# Pin the URL in wp-config.php too. The constants override the database,
	# so a migration import that drags in an http:// home can't flip the site
	# back — and they replace blueprint defaults like 'http://' . HTTP_HOST.
	for c in WP_HOME WP_SITEURL; do
		CUR=$($WP config get "$c" --type=constant 2>/dev/null || echo "")
		if [[ "$CUR" == "$CANONICAL" ]]; then
			skip "$c already $CANONICAL in wp-config.php"
		else
			run $WP config set "$c" "$CANONICAL" --type=constant --quiet
			ok "set $c to $CANONICAL in wp-config.php (was: ${CUR:-unset})"
		fi
	done

	if (( ! SKIP_TLS )); then
		if $WP config has FORCE_SSL_ADMIN --type=constant 2>/dev/null; then
			skip "FORCE_SSL_ADMIN already defined"
		else
			run $WP config set FORCE_SSL_ADMIN true --raw --type=constant
			ok "set FORCE_SSL_ADMIN"
		fi
	fi

	# Behind Cloudflare or a load balancer, the origin sees plain HTTP, so
	# is_ssl() returns false. That breaks canonical redirects (often into a
	# loop), mixed content, and anything gated on a secure transport —
	# WordPress application passwords and OAuth flows among them.
	if (( BEHIND_PROXY )); then
		if grep -q 'PROXY_HTTPS_DETECT' "$DOCROOT/wp-config.php"; then
			skip "proxy HTTPS detection already present in wp-config.php"
		elif ! command -v python3 >/dev/null 2>&1; then
			warn "python3 not found — cannot edit wp-config.php safely, add this by hand"
			warn "  above the \"That's all, stop editing\" line:"
			warn "    if ( isset( \$_SERVER['HTTP_X_FORWARDED_PROTO'] )"
			warn "        && 'https' === strtolower( explode( ',', \$_SERVER['HTTP_X_FORWARDED_PROTO'] )[0] ) ) {"
			warn "        \$_SERVER['HTTPS'] = 'on';"
			warn "    }"
		elif (( DRY_RUN )); then
			printf '    %swould insert:%s X-Forwarded-Proto block into wp-config.php\n' "$C_SKIP" "$C_OFF"
		else
			cp -a "$DOCROOT/wp-config.php" "$DOCROOT/wp-config.php.bak.$(date +%Y%m%d%H%M%S)"
			# Must run before wp-settings.php, so insert above the sentinel.
			python3 - "$DOCROOT/wp-config.php" <<'PYEOF'
import sys, io

path = sys.argv[1]
src = io.open(path, encoding='utf-8').read()

block = (
    "\n/* PROXY_HTTPS_DETECT: trust the proxy's protocol header. */\n"
    "if ( isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] )\n"
    "\t&& 'https' === strtolower( explode( ',', $_SERVER['HTTP_X_FORWARDED_PROTO'] )[0] ) ) {\n"
    "\t$_SERVER['HTTPS'] = 'on';\n"
    "}\n"
)

sentinel = "/* That's all, stop editing"
if sentinel in src:
    src = src.replace(sentinel, block + "\n" + sentinel, 1)
else:
    src = src.rstrip() + "\n" + block
io.open(path, 'w', encoding='utf-8').write(src)
print("inserted")
PYEOF
			ok "added X-Forwarded-Proto handling to wp-config.php"
		fi
	else
		skip "not behind a proxy — no X-Forwarded-Proto handling needed"
	fi
fi
fi # DO_WP

# ------------------------------------------------------------ 5. plugins ----

if (( ! DO_PLUGINS )); then
	step "5. Plugins — not selected"
else
step "5. Plugins"

WP="wp --path=$DOCROOT --allow-root"
if ! command -v wp >/dev/null 2>&1; then
	warn "wp-cli not installed — skipping"
elif ! $WP core is-installed 2>/dev/null; then
	warn "no working WordPress in $DOCROOT — skipping"
else
	for p in "${WP_PLUGINS[@]}"; do
		if ! $WP plugin is-installed "$p" 2>/dev/null; then
			run $WP plugin install "$p" --activate --quiet
			ok "installed + activated $p"
		elif ! $WP plugin is-active "$p" 2>/dev/null; then
			run $WP plugin activate "$p" --quiet
			ok "activated $p"
		else
			skip "$p already active"
		fi
	done

	# Breakdance updates itself through its licence once installed, so this
	# only ever installs it — it never overwrites an existing copy.
	if $WP plugin is-installed breakdance 2>/dev/null; then
		if $WP plugin is-active breakdance 2>/dev/null; then
			skip "breakdance already active"
		else
			run $WP plugin activate breakdance --quiet
			ok "activated breakdance"
		fi
	elif [[ -n "$BREAKDANCE_ZIP" ]]; then
		[[ "$BREAKDANCE_ZIP" == http* || -f "$BREAKDANCE_ZIP" ]] || die "--breakdance: $BREAKDANCE_ZIP not found"
		run $WP plugin install "$BREAKDANCE_ZIP" --activate --quiet
		ok "installed + activated breakdance — enter the licence key in its setup wizard"
	else
		warn "breakdance not installed — download the zip from breakdance.com and re-run with"
		warn "    --plugins --breakdance /path/to/breakdance.zip"
	fi

	(( DRY_RUN )) || chown -R www-data:www-data "$DOCROOT/wp-content"
fi
fi # DO_PLUGINS

# ------------------------------------------------------------- 6. verify ----

step "6. Verification"

if (( ! DO_VERIFY )); then
	skip "not selected"
elif (( DRY_RUN )); then
	skip "dry run — nothing to verify"
else
	SCHEME=$( (( SKIP_TLS )) && echo http || echo https )
	for host in "$DOMAIN" $( (( WITH_WWW )) && echo "www.$DOMAIN" ); do
		for path in "/" "/wp-json/"; do
			url="$SCHEME://$host$path"
			# The trailing \n matters: without it read hits EOF, returns 1, and set -e exits.
			read -r code ctype < <(curl -s -o /dev/null -m 20 -w '%{http_code} %{content_type}\n' "$url" || true) || true
			code=${code:-000}
			case "$path:$code" in
				/wp-json/:200)
					ok "$url -> $code $ctype" ;;
				/wp-json/:*)
					warn "$url -> $code $ctype"
					warn "  iso-8859-1 here means Apache never reached index.php — rewrites still broken" ;;
				*:200)
					ok "$url -> $code $ctype" ;;
				/:301|/:302)
					ok "$url -> $code (redirect to $CANONICAL)" ;;
				*)
					warn "$url -> $code $ctype" ;;
			esac
		done
	done
fi

step "Done"
cat <<'NEXT'
    Next, by hand:
      sudo certbot renew --dry-run        verify renewal end to end
      wp option get home                  confirm the canonical URL

    After importing a database from elsewhere, read the "After a migration"
    section of README.md before trusting a search-replace.
NEXT

# ------------------------------------------------------------- report -------
#
# Read-only. Checks the state of the whole host regardless of which steps ran,
# so a partial run still shows what is left to do.

REPORT_FAILS=0
REPORT_ROWS=()

# rpt STATUS LABEL DETAIL — STATUS is PASS, WARN, FAIL or N/A.
rpt() {
	[[ "$1" == FAIL ]] && REPORT_FAILS=$((REPORT_FAILS + 1))
	REPORT_ROWS+=("$1|$2|$3")
}

HOSTS=("$DOMAIN")
(( WITH_WWW )) && HOSTS+=("www.$DOMAIN")

# --- rewrites
if ! command -v apache2ctl >/dev/null 2>&1; then
	rpt FAIL "apache2" "not installed"
else
	apache2ctl -M 2>/dev/null | grep -q rewrite_module \
		&& rpt PASS "mod_rewrite" "enabled" \
		|| rpt FAIL "mod_rewrite" "not enabled — run with --htaccess"

	# Only the <Directory /var/www/> block matters for the docroot.
	if sed -n '\#<Directory /var/www/>#,\#</Directory>#p' /etc/apache2/apache2.conf 2>/dev/null \
		| grep -qE '^\s*AllowOverride\s+All'; then
		rpt PASS "AllowOverride" "All for /var/www/"
	else
		rpt FAIL "AllowOverride" "not All for /var/www/ — .htaccess is ignored"
	fi
fi

if [[ ! -f "$DOCROOT/.htaccess" ]]; then
	rpt FAIL ".htaccess" "missing — run with --htaccess"
elif ! grep -q "BEGIN WordPress" "$DOCROOT/.htaccess"; then
	rpt FAIL ".htaccess" "present but no WordPress block"
elif ! grep -q "HTTP_AUTHORIZATION" "$DOCROOT/.htaccess"; then
	rpt WARN ".htaccess" "WordPress block, no HTTP_AUTHORIZATION — app passwords will 401"
else
	rpt PASS ".htaccess" "WordPress block + HTTP_AUTHORIZATION"
fi

# --- certbot
if (( SKIP_TLS )); then
	rpt N/A "certbot" "--skip-tls"
elif ! command -v certbot >/dev/null 2>&1; then
	rpt FAIL "certbot" "not installed — run with --certbot"
else
	CERTBOT_BIN=$(command -v certbot)
	[[ "$CERTBOT_BIN" == /snap/* ]] && CERTBOT_SRC=snap || CERTBOT_SRC=apt
	rpt PASS "certbot" "$CERTBOT_SRC, $($CERTBOT_BIN --version 2>&1 | tail -1)"

	# The renewal conf records which plugin renew will use. If it says apache,
	# renewal fails outright without the plugin — so this is the check that
	# actually confirms whether the plugin is needed, not just whether it's there.
	RENEW_CONF="/etc/letsencrypt/renewal/$DOMAIN.conf"
	AUTHENTICATOR=$(sed -n 's/^\s*authenticator\s*=\s*//p' "$RENEW_CONF" 2>/dev/null | head -1 || true)
	INSTALLER=$(sed -n 's/^\s*installer\s*=\s*//p' "$RENEW_CONF" 2>/dev/null | head -1 || true)
	if [[ -n "$AUTHENTICATOR" ]]; then
		NEED_WHY="renewal uses authenticator=$AUTHENTICATOR installer=${INSTALLER:-none}"
	else
		NEED_WHY="no renewal conf yet; this script issues with --apache"
	fi
	if certbot plugins 2>/dev/null | grep -q '^\* apache'; then
		rpt PASS "apache plugin" "installed ($NEED_WHY)"
	elif [[ -n "$AUTHENTICATOR" && "$AUTHENTICATOR" != apache && "${INSTALLER:-}" != apache ]]; then
		rpt N/A "apache plugin" "not installed, not needed ($NEED_WHY)"
	else
		rpt FAIL "apache plugin" "NOT installed but required ($NEED_WHY) — apt install python3-certbot-apache"
	fi

	CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
	if [[ ! -f "$CERT" ]]; then
		rpt FAIL "certificate" "none at $CERT — run with --certbot"
	else
		SANS=$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null \
			| tr ',' '\n' | sed -n 's/.*DNS://p' | tr -d ' ' | tr '\n' ' ' || true)
		MISSING=""
		for host in "${HOSTS[@]}"; do
			grep -qw "$host" <<<"$SANS" || MISSING="$MISSING $host"
		done
		[[ -z "$MISSING" ]] \
			&& rpt PASS "cert names" "$SANS" \
			|| rpt FAIL "cert names" "has: $SANS missing:$MISSING"

		END=$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | cut -d= -f2 || true)
		END_TS=$(date -d "$END" +%s 2>/dev/null || echo "")
		[[ -n "$END" && -n "$END_TS" ]] && DAYS=$(( (END_TS - $(date +%s)) / 86400 ))
		if [[ -z "$END" || -z "$END_TS" ]]; then
			rpt FAIL "cert expiry" "could not read expiry from $CERT"
		elif (( DAYS < 0 )); then
			rpt FAIL "cert expiry" "EXPIRED $END"
		elif (( DAYS < 14 )); then
			rpt WARN "cert expiry" "$DAYS days ($END) — renewal should have run by now"
		else
			rpt PASS "cert expiry" "$DAYS days ($END)"
		fi
	fi
fi

# --- renewal scheduler
if (( ! SKIP_TLS )); then
	TIMER_FOUND=""
	for t in certbot.timer snap.certbot.renew.timer; do
		systemctl list-unit-files "$t" 2>/dev/null | grep -q "^$t" || continue
		TIMER_FOUND=$t
		EN=$(systemctl is-enabled "$t" 2>/dev/null || true)
		AC=$(systemctl is-active "$t" 2>/dev/null || true)
		NEXT_RUN=$(systemctl list-timers --all 2>/dev/null | awk -v t="$t" '$0 ~ t {print $1, $2, $3}' | head -1 || true)
		if [[ "$EN" == enabled && "$AC" == active ]]; then
			rpt PASS "renew scheduler" "$t enabled+active, next: ${NEXT_RUN:-unknown}"
		else
			rpt FAIL "renew scheduler" "$t is $EN/$AC — systemctl enable --now $t"
		fi
	done
	if [[ -z "$TIMER_FOUND" ]]; then
		if [[ -f /etc/cron.d/certbot ]] && [[ ! -d /run/systemd/system ]]; then
			rpt PASS "renew scheduler" "/etc/cron.d/certbot (no systemd)"
		else
			rpt FAIL "renew scheduler" "no certbot timer or cron — cert will EXPIRE"
		fi
	fi

	RELOAD_HOOK="/etc/letsencrypt/renewal-hooks/deploy/reload-apache.sh"
	if [[ -x "$RELOAD_HOOK" ]]; then
		rpt PASS "reload hook" "$RELOAD_HOOK"
	elif [[ -f "$RELOAD_HOOK" ]]; then
		rpt FAIL "reload hook" "$RELOAD_HOOK not executable"
	else
		rpt FAIL "reload hook" "missing — Apache will serve the old cert after renewal"
	fi
fi

# --- WordPress
if ! command -v wp >/dev/null 2>&1; then
	rpt WARN "wp-cli" "not installed — WordPress settings not checked"
elif [[ ! -f "$DOCROOT/wp-config.php" ]]; then
	rpt WARN "wp-config.php" "not found in $DOCROOT"
else
	WP="wp --path=$DOCROOT --allow-root"
	for opt in home siteurl; do
		VAL=$($WP option get "$opt" 2>/dev/null || echo "?")
		[[ "$VAL" == "$CANONICAL" ]] \
			&& rpt PASS "wp $opt" "$VAL" \
			|| rpt FAIL "wp $opt" "$VAL (want $CANONICAL)"
	done
	for c in WP_HOME WP_SITEURL; do
		VAL=$($WP config get "$c" --type=constant 2>/dev/null || echo "")
		[[ "$VAL" == "$CANONICAL" ]] \
			&& rpt PASS "$c" "$VAL in wp-config.php" \
			|| rpt FAIL "$c" "${VAL:-unset} in wp-config.php (want $CANONICAL) — run with --wp-urls"
	done
	if (( ! SKIP_TLS )); then
		$WP config has FORCE_SSL_ADMIN --type=constant 2>/dev/null \
			&& rpt PASS "FORCE_SSL_ADMIN" "defined" \
			|| rpt WARN "FORCE_SSL_ADMIN" "not defined"
	fi
	if (( BEHIND_PROXY )); then
		grep -q 'PROXY_HTTPS_DETECT' "$DOCROOT/wp-config.php" \
			&& rpt PASS "proxy HTTPS" "X-Forwarded-Proto block present" \
			|| rpt FAIL "proxy HTTPS" "missing — is_ssl() will be false behind the proxy"
	fi
	for p in "${WP_PLUGINS[@]}" breakdance; do
		if $WP plugin is-active "$p" 2>/dev/null; then
			rpt PASS "plugin" "$p $($WP plugin get "$p" --field=version 2>/dev/null || true)"
		elif $WP plugin is-installed "$p" 2>/dev/null; then
			rpt WARN "plugin" "$p installed but inactive"
		else
			rpt WARN "plugin" "$p not installed — run with --plugins"
		fi
	done
	for p in akismet hello; do
		$WP plugin is-installed "$p" 2>/dev/null && rpt WARN "plugin" "$p (bundled) still installed"
	done
fi

if command -v php >/dev/null 2>&1; then
	PHPV=$(php -r 'echo PHP_VERSION;')
	# WordPress recommends 8.3+.
	if php -r 'exit(version_compare(PHP_VERSION, "8.3", ">=") ? 0 : 1);'; then
		rpt PASS "php" "$PHPV"
	else
		rpt WARN "php" "$PHPV — older than 8.3"
	fi
fi

step "Report for $DOMAIN"
for row in "${REPORT_ROWS[@]}"; do
	IFS='|' read -r status label detail <<<"$row"
	case "$status" in
		PASS) color=$C_OK ;;
		WARN) color=$C_WARN ;;
		FAIL) color=$C_ERR ;;
		*)    color=$C_SKIP ;;
	esac
	printf '    %s%-4s%s  %-16s %s\n' "$color" "$status" "$C_OFF" "$label" "$detail"
done
echo
if (( REPORT_FAILS )); then
	printf '    %s%d check(s) failed%s\n' "$C_ERR" "$REPORT_FAILS" "$C_OFF"
	(( DRY_RUN )) || exit 1
else
	printf '    %sall checks passed%s\n' "$C_OK" "$C_OFF"
fi
