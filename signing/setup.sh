#!/bin/bash
# Skapar en lokal, självsignerad kodsigneringsidentitet i en egen nyckelring här i mappen.
# Den gör att macOS känner igen appen mellan byggen, så att behörigheter (skärminspelning, kamera)
# inte försvinner vid varje ./build.sh. Inloggningsnyckelringen påverkas inte.
# Ta bort identiteten: rm bss-signing.keychain-db cert.pem
set -euo pipefail
cd "$(dirname "$0")"
KEYCHAIN="$PWD/bss-signing.keychain-db"
[ -f "$KEYCHAIN" ] && { echo "Already exists: $KEYCHAIN"; exit 0; }

openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf
# macOS kan bara läsa PKCS12 med äldre kryptering.
openssl pkcs12 -export -inkey key.pem -in cert.pem -out identity.p12 -passout pass:bss \
    -name "BetterScreenSharing Local" -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

security create-keychain -p bss "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p bss "$KEYCHAIN"
security import identity.p12 -k "$KEYCHAIN" -P bss -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k bss "$KEYCHAIN" >/dev/null
rm -f key.pem identity.p12
echo "Done. ./build.sh now signs with \"BetterScreenSharing Local\"."
