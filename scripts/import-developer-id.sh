#!/usr/bin/env bash
# Moves the Developer ID Application identity into devops/secrets/release.enc.yaml
# for the Release workflow, under a new random password:
#
#   scripts/import-developer-id.sh PKCS12_FILE
#
# It asks for the PKCS#12 file's password without echoing it, keeps only the
# certificate for team D82Y886BX5 and its private key, and writes them with
# the Developer ID G2 intermediate as DEVELOPER_ID_P12 (base64) and
# DEVELOPER_ID_P12_PASSWORD. Nothing unencrypted is written outside a private
# temporary folder, which is removed on exit. Needs sops, OpenSSL 3 or later
# (Homebrew's openssl) and the gizlet age identity (SOPS_AGE_KEY or the
# io.gizlet.sops.age Keychain item).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
secrets=${root}/devops/secrets/release.enc.yaml
team=D82Y886BX5
source_p12=${1:?usage: import-developer-id.sh PKCS12_FILE}
openssl=$(command -v /opt/homebrew/opt/openssl@4/bin/openssl /opt/homebrew/opt/openssl@3/bin/openssl openssl | head -n 1)
"${openssl}" version | grep -q '^OpenSSL [3-9]' || { echo "error: needs OpenSSL 3 or later, not $("${openssl}" version)" >&2; exit 1; }
if [ -z "${SOPS_AGE_KEY:-}" ]; then
    SOPS_AGE_KEY=$(security find-generic-password -s io.gizlet.sops.age -a "${USER}" -w)
    export SOPS_AGE_KEY
fi

umask 077
work=$(mktemp -d)
trap 'rm -rf -- "${work}"' EXIT

printf 'Password of %s: ' "${source_p12}" >&2
IFS= read -rs password </dev/tty
printf '\n' >&2
# Old Keychain exports use RC2 and 3DES, which OpenSSL 3 reads with the legacy provider.
"${openssl}" pkcs12 -in "${source_p12}" -legacy -nodes -passin fd:3 -out "${work}/all.pem" 3<<<"${password}" 2>/dev/null ||
    "${openssl}" pkcs12 -in "${source_p12}" -nodes -passin fd:3 -out "${work}/all.pem" 3<<<"${password}" ||
    { echo 'error: cannot read the file (wrong password?)' >&2; exit 1; }
unset password

# Split the bundle into its certificates and keys.
awk -v dir="${work}" '
    /-----BEGIN CERTIFICATE-----/ { n++; out = dir "/cert" n ".pem" }
    /-----BEGIN (RSA |EC )?PRIVATE KEY-----/ { k++; out = dir "/key" k ".pem" }
    out { print > out }
    /-----END/ { close(out); out = "" }
' "${work}/all.pem"

cert=''
for c in "${work}"/cert*.pem; do
    subject=$("${openssl}" x509 -in "${c}" -noout -subject -nameopt RFC2253)
    case "${subject}" in *"CN=Developer ID Application:"*) ;; *) continue ;; esac
    case ",${subject}," in *",OU=${team},"*) ;; *) continue ;; esac
    "${openssl}" x509 -in "${c}" -noout -checkend 2592000 >/dev/null || { echo "skipping a certificate that expires within 30 days: ${subject}" >&2; continue; }
    cert=${c}
done
[ -n "${cert}" ] || { echo "error: no valid Developer ID Application certificate for ${team} in the file" >&2; exit 1; }
want=$("${openssl}" x509 -in "${cert}" -noout -pubkey | "${openssl}" pkey -pubin -outform der | shasum -a 256)
key=''
for k in "${work}"/key*.pem; do
    [ "$("${openssl}" pkey -in "${k}" -pubout -outform der 2>/dev/null | shasum -a 256)" = "${want}" ] && key=${k}
done
[ -n "${key}" ] || { echo 'error: the file has no private key for the Developer ID certificate' >&2; exit 1; }

new_password=$("${openssl}" rand -hex 24)
# Legacy encryption, which every macOS `security import` reads.
"${openssl}" x509 -inform der -in "${root}/devops/apple/DeveloperIDG2CA.cer" -out "${work}/intermediate.pem"
"${openssl}" pkcs12 -export -legacy -inkey "${key}" -in "${cert}" -certfile "${work}/intermediate.pem" \
    -name "Developer ID Application (${team})" -passout fd:3 -out "${work}/identity.p12" 3<<<"${new_password}"

sops set "${secrets}" '["DEVELOPER_ID_P12"]' "\"$(base64 < "${work}/identity.p12" | tr -d '\n')\""
sops set "${secrets}" '["DEVELOPER_ID_P12_PASSWORD"]' "\"${new_password}\""
"${openssl}" x509 -in "${cert}" -noout -subject -enddate -fingerprint -sha1
echo "Stored in ${secrets#"${root}/"}. Commit it to a pull request." >&2
