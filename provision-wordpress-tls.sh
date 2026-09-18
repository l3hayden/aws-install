#!/usr/bin/env bash
#
# Provision a fresh Debian/Ubuntu + Apache + WordPress host: rewrites, TLS,
# renewal, and the WordPress-side URL settings.
#
# Idempotent — safe to re-run. Every step checks its own state first and says
# what it did or why it skipped.
#
#   sudo ./provision-wordpress-tls.sh --domain example.co.nz --email you@example.com
#   sudo ./provision-wordpress-tls.sh --domain example.co.nz --email you@example.com --dry-run
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
  -h, --help          This message
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
		-h|--help)      usage; exit 0 ;;
		*)              echo "Unknown option: $1" >&2; usage; exit 1 ;;
	esac
done

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
if (( ! SKIP_TLS )); then
	[[ -n "$EMAIL" ]] || { usage; die "--email is required unless --skip-tls"; }
fi
[[ $EUID -eq 0 ]] || die "run this with sudo"

command -v apache2ctl >/dev/null 2>&1 || die "apache2 not found — this script targets Debian/Ubuntu Apache"
[[ -d "$DOCROOT" ]] || die "docroot $DOCROOT does not exist"
[[ -f "$DOCROOT/wp-config.php" || -f "$DOCROOT/wp-load.php" ]] \
	|| warn "no wp-config.php in $DOCROOT — continuing, but the WordPress steps will be skipped"

ok "domain      : $DOMAIN"
(( WITH_WWW )) && ok "www variant : www.$DOMAIN" || skip "www variant : not requested"
ok "docroot     : $DOCROOT"
(( DRY_RUN ))  && warn "DRY RUN — nothing will be modified"

# DNS has to resolve before certbot's HTTP-01 challenge can possibly work.
if (( ! SKIP_TLS )); then
	for host in "$DOMAIN" $( (( WITH_WWW )) && echo "www.$DOMAIN" ); do
		if getent hosts "$host" >/dev/null 2>&1; then
			ok "DNS resolves: $host -> $(getent hosts "$host" | awk '{print $1}' | head -1)"
		else
			die "DNS does not resolve for $host — certbot will fail. Fix DNS first."
		fi
	done
fi

# ----------------------------------------------------------- 1. rewrites ----
#
# The single most common cause of "/wp-json/ 404s and every pretty permalink
# is broken". A fresh WordPress uses plain permalinks and needs none of this,
# so the fault stays invisible until a database import brings a real
# permalink_structure with it.

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

# ---------------------------------------------------------------- 2. TLS ----

if (( SKIP_TLS )); then
	step "2. TLS — skipped (--skip-tls)"
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

if (( SKIP_TLS )); then
	step "3. Renewal — skipped (--skip-tls)"
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

step "4. WordPress URL configuration"

if ! command -v wp >/dev/null 2>&1; then
	warn "wp-cli not installed — skipping. Install it with:"
	warn "    curl -sO https://raw.githubusercontent.com/wp-cli/wp-cli/v2.9.0/phar/wp-cli.phar"
	warn "    chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp"
elif [[ ! -f "$DOCROOT/wp-config.php" ]]; then
	warn "no wp-config.php in $DOCROOT — skipping"
else
	WP="wp --path=$DOCROOT --allow-root"
	SCHEME=$( (( SKIP_TLS )) && echo http || echo https )
	CANONICAL="$SCHEME://$( (( WITH_WWW )) && echo "www.$DOMAIN" || echo "$DOMAIN" )"

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

# ------------------------------------------------------------- 5. verify ----

step "5. Verification"

if (( DRY_RUN )); then
	skip "dry run — nothing to verify"
else
	SCHEME=$( (( SKIP_TLS )) && echo http || echo https )
	for host in "$DOMAIN" $( (( WITH_WWW )) && echo "www.$DOMAIN" ); do
		for path in "/" "/wp-json/"; do
			url="$SCHEME://$host$path"
			read -r code ctype < <(curl -s -o /dev/null -m 20 -w '%{http_code} %{content_type}' "$url" || echo "000 -")
			case "$path:$code" in
				/wp-json/:200)
					ok "$url -> $code $ctype" ;;
				/wp-json/:*)
					warn "$url -> $code $ctype"
					warn "  iso-8859-1 here means Apache never reached index.php — rewrites still broken" ;;
				*:200)
					ok "$url -> $code $ctype" ;;
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
