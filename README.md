# Provisioning a WordPress host on Lightsail

Everything a fresh Debian/Ubuntu + Apache + WordPress instance needs before it
can serve a real site: rewrite rules, a TLS certificate that covers every name
people actually type, renewal that survives unattended, and the WordPress-side
URL settings.

`provision-wordpress-tls.sh` does all of it. This file explains what each step
is for and which failure it prevents — every one of them is something that has
actually bitten us, not a hypothetical.

> **Not for Bitnami.** The Lightsail *WordPress* blueprint is a Bitnami image:
> docroot `/opt/bitnami/wordpress`, its own Apache, and `bncert-tool` instead of
> certbot. This script targets a plain Debian/Ubuntu instance with docroot
> `/var/www/html`. Check with `ls /opt/bitnami` before you start.

## Usage

```bash
ssh admin@HOST
curl -fsSLO https://raw.githubusercontent.com/l3hayden/aws-install/main/provision-wordpress-tls.sh
chmod +x provision-wordpress-tls.sh

# See what it would do, change nothing
sudo ./provision-wordpress-tls.sh --domain example.co.nz --email you@example.com --dry-run

# Do it
sudo ./provision-wordpress-tls.sh --domain example.co.nz --email you@example.com
```

Behind Cloudflare or a load balancer that terminates TLS, add `--behind-proxy`.

| Flag | Effect |
|---|---|
| `--domain` | Apex domain, no scheme, no `www`. Required. |
| `--email` | Let's Encrypt registration and expiry notices. Required unless `--skip-tls`. |
| `--docroot` | Default `/var/www/html`. |
| `--no-www` | Cert for the apex only. Default is apex **and** `www`. |
| `--behind-proxy` | Adds `X-Forwarded-Proto` handling to `wp-config.php`. |
| `--skip-tls` | Rewrites and WordPress settings only. |
| `--dry-run` | Print intended changes, touch nothing. |

Re-running is safe. Each step checks its own state and reports `✓` for done,
`·` for already correct, `!` for needs attention. Files are backed up with a
timestamp suffix before being replaced.

Requires `python3` for the `--behind-proxy` wp-config edit (present on any host
with apt certbot). Without it the script prints the snippet for you to paste.

## What it does, and why

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

Also check `/etc/letsencrypt/renewal/DOMAIN.conf` lists every domain. That file
is what renewal replays, so if it only has the apex you quietly lose the `www`
SAN at the next renewal.

If you genuinely prefer cron to timers, disable the built-in one first:

```bash
systemctl disable --now certbot.timer
# 0 3,15 * * * certbot renew --quiet --deploy-hook "systemctl reload apache2"
```

### 4. WordPress URLs

Sets `home` and `siteurl` to the canonical URL and defines `FORCE_SSL_ADMIN`.

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
```

Check the **bare** domain as well as `www` — a cert missing the apex only shows
up if you test it.
