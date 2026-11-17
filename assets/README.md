# assets

## branding

`branding/icon.svg` is the source of the app icon ("caret wave": four grey sound bars ending in a lime text cursor, on a graphite tile drawn on the macOS 824 grid). `icon-previous.svg` is the earlier bars-and-lines mark, kept for reference.

Rebuild the derived files after editing `icon.svg`. The SVG is rasterised with AppKit (no packages needed):

```bash
cd assets/branding
# render icon.png at 1024 with a transparent background (small Swift script using NSImage + NSBitmapImageRep)
mkdir -p AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s icon.png --out AppIcon.iconset/icon_${s}x${s}.png
  sips -z $((s*2)) $((s*2)) icon.png --out AppIcon.iconset/icon_${s}x${s}@2x.png
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
```

`build.sh` copies `AppIcon.icns` into the bundle and sets `CFBundleIconFile`.

## Stable code signing

macOS ties the microphone and screen recording grants to the app's designated requirement. An ad-hoc signature changes on every build, so the grants were re-asked each time. `build.sh` therefore signs with a local self-signed certificate called **Scribe Local Signing** when it is in the login keychain, and falls back to ad-hoc otherwise. With the certificate the designated requirement is `identifier "com.akshaybengani.scribe" and certificate leaf = H"<sha1 of the certificate>"`, identical on every rebuild.

One-time setup, login keychain only, no admin password:

```bash
cd "$(mktemp -d)"
cat > cs.cnf <<'EOF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Scribe Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout k.pem -out c.pem -days 3650 -config cs.cnf
PW="$(openssl rand -hex 16)"
# OpenSSL 3 and later need the legacy PBE flags or `security import` reports a MAC failure
openssl pkcs12 -export -inkey k.pem -in c.pem -name "Scribe Local Signing" -out s.p12 -passout "pass:$PW" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import s.p12 -k ~/Library/Keychains/login.keychain-db -P "$PW" -T /usr/bin/codesign
rm -P k.pem; rm -f s.p12
```

The first signing run may show a keychain prompt asking whether `codesign` may use the key: choose Always Allow. The certificate is listed as `CSSMERR_TP_NOT_TRUSTED` by `security find-identity`, which is fine for signing a local build. Never export or commit the private key.

Check that the requirement is stable:

```bash
NO_INSTALL=1 ./build.sh   # note the printed .app path
codesign -d -r- /path/to/Scribe.app   # run again after a rebuild, the line must be identical
```

After the first install with the certificate, macOS asks for the microphone and screen recording permissions one last time. They stay granted across later rebuilds.

## fonts

`fonts/` holds the two typefaces the Graphite design uses, copied unchanged from their official releases:

- Inter 4.1 (rsms/inter): Regular, Medium, SemiBold, Bold. Licence: `fonts/Inter-OFL.txt`.
- JetBrains Mono 2.304 (JetBrains/JetBrainsMono): Regular, Medium. Licence: `fonts/JetBrainsMono-OFL.txt`.

Both are under the SIL Open Font License 1.1, which allows bundling and redistribution with the app as long as the licence text travels with the fonts. `build.sh` copies the TTFs and the licence texts into `Scribe.app/Contents/Resources/Fonts`, and `Theme.swift` registers them at launch (`GFont.registerBundled()`) before the first view is created. If the folder is missing the app falls back to SF Pro and SF Mono.
