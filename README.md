# Provisioning a WordPress host on Lightsail

Everything a Debian + Apache + WordPress instance needs before it can serve a
real site: the stack itself on a bare instance, rewrite rules, a TLS
certificate that covers every name people actually type, renewal that survives
unattended, the WordPress-side URL settings, and the plugins every site gets.

`provision-wordpress-tls.sh` does all of it. This file explains what each step
is for and which failure it prevents — every one of them is something that has
actually bitten us, not a hypothetical.

> **Not for Bitnami.** The old Bitnami-packaged Lightsail blueprint uses docroot
> `/opt/bitnami/wordpress`, its own Apache, and `bncert-tool` instead of
> certbot. This script targets a plain Debian instance with docroot
> `/var/www/html`. Check with `ls /opt/bitnami` before you start.

## Usage

### New site on a bare instance

In the Lightsail console:

1. Create an instance from the plain **Debian 13** OS blueprint, not the
   WordPress one.
2. **Attach a static IP** (Networking tab). The default public IP changes
   whenever the instance is stopped and started.
3. **Open port 443** in the instance firewall. Lightsail opens only 22 and 80
   by default; the certificate still issues without 443 (Let's Encrypt checks
   over 80), but nobody can reach the site over https.
4. Add `A` records for the apex and `www` pointing at the static IP. No `www`
   wanted, e.g. for a subdomain? Skip that record and add `--no-www` below.
   Put the records in whichever DNS provider the domain's nameservers point
   at — a record in Lightsail's own DNS zones does nothing if the domain uses
   Cloudflare.

Then on the instance:

```bash
ssh admin@HOST
curl -fsSLO https://raw.githubusercontent.com/l3hayden/aws-install/main/provision-wordpress-tls.sh
chmod +x provision-wordpress-tls.sh

# Upload the Breakdance zip first (it needs a breakdance.com login to download):
#   scp breakdance.zip admin@HOST:~

sudo ./provision-wordpress-tls.sh --domain example.co.nz --email you@example.com \
  --install --redis --breakdance ~/breakdance.zip
```

That installs the stack and WordPress, then runs every other step: `.htaccess`,
certificate, renewal, URLs, plugins, Redis, verification and the report. The
WordPress and database passwords are in `~/wordpress_credentials`. Drop
`--redis` for a site without an object cache.

Before requesting a certificate, the script checks DNS against **public**
resolvers (Cloudflare, falling back to Google). That's what Let's Encrypt
uses, and it avoids stale caches: if a name was looked up before its record
existed, your PC, router or the instance can keep answering "doesn't exist"
for as long as the zone's negative TTL (30 minutes on some zones). If a
record is missing or points elsewhere, it prints the exact `A` records to
create with this instance's public IP. To check from your PC the same way,
ask a public resolver directly: `nslookup test.example.co.nz 1.1.1.1`.

If DNS isn't pointing at the instance yet, add `--skip-tls` to get a working
http site now, then run the script again later without `--install` or `--skip-tls`
to add the certificate and switch to https.

### Existing site

```bash
# See what it would do, change nothing
sudo ./provision-wordpress-tls.sh --domain example.co.nz --email you@example.com --dry-run

# Do it
sudo ./provision-wordpress-tls.sh --domain example.co.nz --email you@example.com
```

Behind Cloudflare or a load balancer that terminates TLS, add `--behind-proxy`.

| Flag | Effect |
|---|---|
| `--domain` | Apex domain, no scheme, no `www`. Required. |
| `--email` | Let's Encrypt registration and expiry notices; also the WordPress admin email for `--install`. Required for the certbot step. |
| `--docroot` | Default `/var/www/html`. |
| `--no-www` | Cert for the apex only. Default is apex **and** `www`. |
| `--behind-proxy` | Adds `X-Forwarded-Proto` handling to `wp-config.php`. |
| `--skip-tls` | Rewrites and WordPress settings only. |
| `--dry-run` | Print intended changes, touch nothing. |
| `--admin-user` | WordPress admin username for `--install`. Default `user`. |
| `--admin-email` | WordPress admin email for `--install`. Default: `--email`. |
| `--breakdance` | Breakdance zip, local path or URL, for the plugins step. |

To run only some steps, pass one or more step flags. With none, steps 1–4 and
7 run. `--install` on its own runs steps 0–5 and 7; add `--redis` for step 6.

| Step flag | Runs |
|---|---|
| `--install` | Step 0: Apache, PHP-FPM, MariaDB, wp-cli and the latest WordPress on bare Debian 13 |
| `--htaccess` | Step 1: `mod_rewrite`, `AllowOverride All`, the WordPress `.htaccess` |
| `--certbot` | Step 2: install certbot and the apache plugin, obtain or expand the cert. Needs `--email`. |
| `--renewal` | Step 3: check the renewal timer (starting it if it's stopped), install the Apache reload hook |
| `--wp-urls` | Step 4: `WP_HOME`/`WP_SITEURL` in `wp-config.php`, `home`/`siteurl`, `FORCE_SSL_ADMIN`, and with `--behind-proxy` the proxy HTTPS block |
| `--plugins` | Step 5: install and activate the standard plugins |
| `--redis` | Step 6: Redis server, `php-redis`, Redis Object Cache, object cache enabled |
| `--verify` | Step 7: curl `/` and `/wp-json/` on every name |

```bash
sudo ./provision-wordpress-tls.sh --domain example.co.nz --htaccess --verify
sudo ./provision-wordpress-tls.sh --domain example.co.nz --email you@example.com --certbot --renewal
sudo ./provision-wordpress-tls.sh --domain example.co.nz --plugins --breakdance ~/breakdance.zip
sudo ./provision-wordpress-tls.sh --domain example.co.nz --redis
```

`--skip-tls` can't be combined with `--certbot` or `--renewal`.

### Status report

Every run ends with a read-only report on the whole host, whichever steps
ran. `--report` prints only the report and changes nothing:

```bash
sudo ./provision-wordpress-tls.sh --domain example.co.nz --report
```

```
==> Report for example.co.nz
    PASS  mod_rewrite      enabled
    PASS  AllowOverride    All for /var/www/
    PASS  .htaccess        WordPress block + HTTP_AUTHORIZATION
    PASS  certbot          apt, certbot 2.1.0
    FAIL  apache plugin    NOT installed but required (renewal uses authenticator=apache installer=apache) — apt install python3-certbot-apache
    FAIL  cert names       has: example.co.nz  missing: www.example.co.nz
    PASS  cert expiry      59 days (Nov 18 00:19:06 2026 GMT)
    PASS  renew scheduler  certbot.timer enabled+active, next: Sat 2026-09-19 22:13:00
    PASS  reload hook      /etc/letsencrypt/renewal-hooks/deploy/reload-apache.sh
    PASS  wp home          https://www.example.co.nz
    ...

    2 check(s) failed
```

The **apache plugin** line reads `/etc/letsencrypt/renewal/DOMAIN.conf` to
see which plugin renewal will actually use. If it says `apache`, renewal fails
outright without `python3-certbot-apache`. If the cert was issued another way
(e.g. `webroot`), the plugin isn't needed and the line shows `N/A`.

The script exits 1 if any line is `FAIL`, so it can gate automation. A
`--dry-run` always exits 0, because its report shows the host before any
changes.

Re-running is safe. Each step checks its own state and reports `✓` for done,
`·` for already correct, `!` for needs attention. Files are backed up with a
timestamp suffix before being replaced.

Requires `python3` for the `--behind-proxy` wp-config edit (present on any host
with apt certbot). Without it the script prints the snippet for you to paste.

## What it does, and why

### 0. Install (`--install`)

Only on **Debian 13**. It's the first Debian release whose own repositories
carry a current PHP (8.4), and certbot's Apache plugin is a normal package.
Debian 12 is stuck on PHP 8.2 without a third-party repo; Amazon Linux 2023
has no certbot package and a different Apache layout altogether.

- **Swap.** A 1 GB swap file if the instance has under 2 GB RAM. MariaDB and
  PHP on a 512 MB or 1 GB plan get killed by the kernel without it.
- **Packages.** `apache2`, `mariadb-server`, `php-fpm` and only the PHP
  extensions WordPress uses (mysql, curl, gd, intl, mbstring, xml, zip,
  opcache). No phpMyAdmin.
- **PHP-FPM, not mod_php.** Runs under Apache's event MPM, the Debian default.
  `/etc/php/8.4/fpm/conf.d/99-wordpress.ini` raises upload and memory limits
  enough for All-in-One WP Migration imports and the Breakdance editor.
- **A vhost for the domain.** `certbot --apache` needs a vhost whose
  `ServerName` matches, or it can't choose one non-interactively.
- **WordPress** from wordpress.org, not Debian's `wordpress` package, which
  lags behind and uses its own layout. The official tarball is unpacked with
  GNU `tar`, **not** `wp core download`: wp-cli's PHP extractor cuts long
  paths short (WordPress 7's `php-ai-client` has plenty) and still reports
  success, leaving a site that loads but has broken core files. Core is then
  checked with `wp core verify-checksums`; re-running `--install` repairs a
  damaged core without touching `wp-content` or `wp-config.php`. Akismet, Hello Dolly and
  every theme except the default are deleted. Permalinks are set to
  `/%postname%/`.
- **Credentials.** The database password and WordPress admin password are
  generated on the instance and written to `~/wordpress_credentials` in the
  home of the user who ran `sudo` (`/home/admin` on Lightsail), mode 600.
  They never leave the host, so nothing secret goes near this repo. Move them
  to your password manager and delete the file.

It refuses to install over a docroot that already has something other than
Debian's placeholder page in it. If WordPress is already installed it leaves
the site alone, apart from repairing core files that fail their checksums, so
re-running is safe.

It also adds a global `ServerName` (silences Apache's AH00558 warning) and
points wp-cli's temporary files at `/var/tmp`. Debian 13 keeps `/tmp` in RAM,
capped at half of it, which on a small instance is too little to unpack
WordPress.

### 1. Rewrite prerequisites

Three things, all of which must be right or none of it works:

```bash
a2enmod rewrite                         # not enabled by default on Debian
AllowOverride None -> All               # for <Directory /var/www/> in apache2.conf
/var/www/html/.htaccess                 # WordPress never writes one unprompted
```

**The failure this prevents.** A fresh WordPress uses *plain* permalinks
(`?p=123`), which need no rewriting, so a host can look perfectly healthy with
all three of these missing. The fault only surfaces when a database import
brings a real `permalink_structure` with it — and then every pretty permalink
and `/wp-json/` starts 404ing at once.

The tell is the **character set** of the 404:

| Response | Meaning |
|---|---|
| `404 text/html; charset=iso-8859-1` | Apache's own error page — the request never reached `index.php`. Rewrites are broken. |
| `404 text/html; charset=UTF-8` | WordPress's themed 404 — routing works, that URL genuinely doesn't exist. |

Quick check on any host:

```bash
curl -s -o /dev/null -w "%{http_code} %{content_type}\n" https://HOST/wp-json/
```

`200 application/json` is healthy. `?rest_route=/` working while `/wp-json/`
404s is the signature of exactly this problem.

Note the `HTTP_AUTHORIZATION` line in the `.htaccess` block:

```apache
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
```

That is not boilerplate. Without it PHP never sees the `Authorization` header,
so **application passwords fail on every REST request** — which takes out MCP
connectors, headless clients, and WP-CLI over HTTP. The symptom is a 401 that
looks like a wrong password.

### 2. certbot

```bash
apt install certbot python3-certbot-apache
certbot --apache -d example.co.nz -d www.example.co.nz --redirect ...
```

**The apache plugin is a separate package.** `certbot` alone gives you
`The apache plugin does not appear to be installed`. A snap-installed certbot
bundles it instead — don't mix the two, pick one:

```bash
which certbot     # /usr/bin/certbot = apt, /snap/bin/certbot = snap
```

**Always pass both names.** `-d example.co.nz -d www.example.co.nz`. A cert
covering only `www` while the HTTP vhost redirects the apex *to the apex* means
anyone typing the bare domain gets a certificate warning — the site is broken
for them and nothing in your monitoring will say so. The script checks the SANs
on an existing cert and reissues with `--expand` if any requested name is
missing.

Verify what's actually being served, not what you think you asked for:

```bash
echo | openssl s_client -connect HOST:443 -servername HOST 2>/dev/null \
  | openssl x509 -noout -subject -dates -ext subjectAltName
```

### 3. Renewal

**Don't write a cron job.** certbot installs its own scheduler — apt drops both
`/etc/cron.d/certbot` and a `certbot.timer` (the cron file self-disables under
systemd); snap installs `snap.certbot.renew.timer`. Adding your own on top
gives you two schedulers contending for the same lock.

```bash
systemctl list-timers --all | grep -i certbot
```

It runs twice daily at a randomised minute and is a no-op until the cert is
within 30 days of expiry.

What *is* missing by default is a reload hook. Apache keeps serving the old
certificate from memory after renewal unless something reloads it, so the
script installs:

```
/etc/letsencrypt/renewal-hooks/deploy/reload-apache.sh
```

Anything in `renewal-hooks/deploy/` runs only after a cert actually renews.
This is the classic silent failure — renewal succeeds, nothing reloads, the
site serves an expired cert for weeks.

Then verify end to end, which is the step everyone skips:

```bash
sudo certbot renew --dry-run
```

Renewal reissues the certificate for the names it already covers. It never
adds one, so a certificate missing `www` stays missing it through every
renewal. Check what each certificate covers with:

```bash
sudo certbot certificates
```

The script's certbot step reissues with `--expand` when a name is missing.

If you genuinely prefer cron to timers, disable the built-in one first:

```bash
systemctl disable --now certbot.timer
# 0 3,15 * * * certbot renew --quiet --deploy-hook "systemctl reload apache2"
```

### 4. WordPress URLs

Sets `home` and `siteurl` to the canonical URL, pins the same URL in
`wp-config.php` as `WP_HOME` and `WP_SITEURL`, and defines `FORCE_SSL_ADMIN`.

The constants override the database. A migration import that brings in an
`http://` home can't switch the site back to http, and blueprint defaults
like `define( 'WP_HOME', 'http://' . $_SERVER['HTTP_HOST'] )` get replaced
with the https URL.

With `--behind-proxy`, inserts this into `wp-config.php` above the
`That's all, stop editing` line:

```php
if ( isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] )
	&& 'https' === strtolower( explode( ',', $_SERVER['HTTP_X_FORWARDED_PROTO'] )[0] ) ) {
	$_SERVER['HTTPS'] = 'on';
}
```

**Why it has to be in wp-config and not an mu-plugin.** It must run before
`wp-settings.php`. Behind Cloudflare the origin sees plain HTTP, so `is_ssl()`
returns false, and that breaks canonical redirects (often into a loop), causes
mixed content, and disables anything gated on a secure transport — WordPress
application passwords and OAuth flows included.

### 5. Plugins (`--plugins`)

Installs and activates the plugins every site gets:

| Plugin | Source |
|---|---|
| All-in-One WP Migration and Backup | wordpress.org, `all-in-one-wp-migration` |
| The SEO Framework | wordpress.org, `autodescription` |
| SMTP2GO | wordpress.org, `smtp2go` |
| Breakdance | `--breakdance ZIP` |

Breakdance isn't on wordpress.org, and the download needs a breakdance.com
login, so the script can't fetch it. Download the zip, `scp` it to the
instance and pass its path, or pass a URL you control (e.g. a presigned S3
link). Then enter the licence key in Breakdance's setup wizard; updates come
through that from then on. An existing Breakdance install is never
overwritten.

The SMTP2GO API key goes in its settings page. It's a secret, so it isn't
handled here.

To change the list, edit `WP_PLUGINS` at the top of the script.

### 6. Redis object cache (`--redis`)

Not part of the default run. Add it when a site should have an object cache.

- **`redis-server` and `php-redis`.** Debian 13 ships Redis 8.0 (Valkey 8.1
  is also packaged; Redis Object Cache works with either). The `php-redis`
  extension is faster than the pure-PHP client the plugin falls back to.
- **Capped, and no disk persistence.** It's a cache, not a datastore. A block
  at the end of `/etc/redis/redis.conf` sets `maxmemory` by instance size
  (64 MB under 1 GB RAM, 128 MB under 2 GB, else 256 MB) and
  `allkeys-lru`, so a full cache evicts old keys instead of eating the memory
  MariaDB and PHP need. Snapshots and the append-only file are off: losing
  the cache on restart costs nothing. Redis listens on localhost only, which
  is the Debian default.
- **WordPress side.** `WP_REDIS_HOST`, `WP_REDIS_PORT` and a
  `WP_REDIS_PREFIX` of `DOMAIN:` in `wp-config.php`. The prefix keeps keys
  apart if two sites ever share one Redis. Then Redis Object Cache
  (`redis-cache`) is installed and activated, and `wp redis enable` writes
  the `object-cache.php` drop-in that actually turns caching on. An existing
  drop-in from a different cache plugin is left alone.

On an existing site it installs only what's missing, but it does apply the
`redis.conf` block and restart Redis and PHP, which empties the cache. The
report shows the object cache connection and Redis's memory cap whenever the
plugin or server is present, so on an older server run `--report` first to
see what's there.

## After a migration

Setting `home` and `siteurl` does **not** fix URLs already embedded in content.
Run a proper search-replace that understands PHP serialisation:

```bash
wp search-replace 'http://old-host' 'https://new-host' --skip-columns=guid --all-tables --dry-run
```

### The trap: page builders that double-encode

`wp search-replace`, All-in-One WP Migration and Better Search Replace all
handle PHP-serialised data. **None of them handle JSON nested inside JSON.**

Breakdance stores each page as:

```json
{"tree_json_string":"{\"root\":{\"id\":1,...}}"}
```

The inner document is embedded as a *string*, so every `/` is escaped twice and
an absolute URL is stored as `http:\\\/\\\/host` — three backslashes before
each slash. Nothing searching for `http://host` matches it.

On one production migration this left **288 stale URLs across 46
pages** pointing at `localhost:8083`, while `siteurl`, `home` and
`post_content` — the plain, once-escaped copies — all migrated correctly. The
site looked fine until you noticed every image was broken.

Check for it after any import:

```bash
wp eval '
global $wpdb;
$host = "old-host";
$bs = chr(92);
$n = 0;
foreach ( range(0,4) as $d ) {
	$sl = str_repeat($bs,$d) . "/";
	$needle = "http:" . $sl . $sl . $host;
	$rows = $wpdb->get_col( $wpdb->prepare(
		"SELECT meta_value FROM {$wpdb->postmeta} WHERE meta_value LIKE %s", "%{$host}%" ) );
	foreach ( $rows as $r ) { $n += substr_count($r, $needle); }
}
echo "escaped occurrences: $n\n";'
```

Two rules if you have to repair them:

- **Match on the escaped form**, built with `chr(92)` rather than literal
  backslashes in your shell — heredocs eat backslash runs, quoted delimiter or
  not.
- **Write with `$wpdb->update()`, never `update_post_meta()`.** The meta API
  calls `wp_unslash()` on the value and strips a backslash level, which
  corrupts every tree it touches.

Validate with `json_decode()` at *both* nesting levels before and after. Note
that a page never built in the builder has an empty `tree_json_string`, and
`json_decode("")` returns null — that's normal, not corruption.

The real fix is upstream: **author image and file URLs root-relative**
(`/wp-content/uploads/...`). Relative URLs survive a host change untouched.

## Post-provision checklist

```bash
curl -s -o /dev/null -w "%{http_code} %{content_type}\n" https://DOMAIN/wp-json/   # 200 application/json
curl -s -o /dev/null -w "%{http_code}\n" https://DOMAIN/some-real-page/            # 200
echo | openssl s_client -connect DOMAIN:443 -servername DOMAIN 2>/dev/null \
  | openssl x509 -noout -dates -ext subjectAltName                                 # both names
sudo certbot renew --dry-run                                                       # passes
systemctl list-timers --all | grep -i certbot                                      # scheduled
wp option get home                                                                 # https, canonical
wp redis status                                                                    # Status: Connected (if --redis)
```

Or run `--report`, which checks all of it.

Check the **bare** domain as well as `www` — a cert missing the apex only shows
up if you test it.
