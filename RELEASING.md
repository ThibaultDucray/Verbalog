# Releasing Verbalog

Releases are Developer ID-signed, notarized disk images, published on GitHub Releases. The app inside is small: it installs Python and the packages from `uv.lock` on first launch (see `BackendLayout.bundled` in `app/Sources/VerbalogCore/Backend.swift`).

## One-time setup

1. **Developer ID certificate.** In Xcode › Settings › Accounts, select your team, then Manage Certificates › + › **Developer ID Application**. Only the account holder of a paid Apple Developer Program membership can create it. Every release shows this team's name to users.
2. **Export it** for CI: in Keychain Access, right-click the certificate › Export, as a `.p12` with a password.
3. **Notarization key.** In App Store Connect › Users and Access › Integrations › Team Keys, generate a key with the Developer role. Download the `AuthKey_<id>.p8` (possible only once), and note the Key ID and the Issuer ID.
4. **On your Mac**, save the key for `notarytool`:
   ```sh
   xcrun notarytool store-credentials verbalog-notary --key AuthKey_<id>.p8 --key-id <key id> --issuer <issuer id>
   ```
5. **On GitHub**, in Settings › Environments, create an environment named `release`. Requiring your approval there means a pushed tag waits for you before anything is signed. Add these secrets to it:

   | Secret | Value |
   |---|---|
   | `DEVELOPER_ID_P12` | `base64 -i developer-id.p12` |
   | `DEVELOPER_ID_P12_PASSWORD` | the export password |
   | `NOTARY_KEY_P8` | `base64 -i AuthKey_<id>.p8` |
   | `NOTARY_KEY_ID` | the Key ID |
   | `NOTARY_ISSUER` | the Issuer ID |

   Then delete the exported `.p12` and keep the `.p8` somewhere safe outside the repository.
6. In Settings › Code security, turn on **Private vulnerability reporting**, which `SECURITY.md` relies on.

## Making a release

1. Make sure `main` passes the tests, and that `uv.lock` is the one you tested with.
2. Tag and push:
   ```sh
   git tag v0.2.0
   git push origin v0.2.0
   ```
3. The **Release** workflow builds, signs, notarizes both the app and the disk image, and creates a **draft** release with `Verbalog-0.2.0.dmg` and its SHA-256.
4. Download the disk image, install it on a Mac, and check that it opens without a Gatekeeper warning. Then edit the notes and publish the draft.

The version comes from the tag. The build number is the commit count, so it only ever grows.

## Building a release locally

```sh
scripts/release.sh 0.2.0                 # needs the certificate and the notarytool profile
SKIP_NOTARIZE=1 scripts/release.sh 0.2.0 # every step except notarization, to test them
```

The result is in `build/dist/`. Upload it with `gh release create v0.2.0 build/dist/Verbalog-0.2.0.dmg*`.

## When dependencies change

An app whose `uv.lock` differs from the installed one shows **Update needed** in Status & Models, and installs the new packages from there. Changing only Swift or the `verbalog` code needs no reinstall: that code runs from the app itself.

To update the bundled `uv`, change `UV_VERSION` and `UV_SHA256` together in `scripts/build-app.sh`, taking the checksum from the `.sha256` file of the uv release.
