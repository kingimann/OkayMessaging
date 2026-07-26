# One-time iOS signing setup

Codemagic can create your Apple distribution certificate and provisioning
profile automatically, but Apple requires a **private key** to sign the
certificate request with. You generate that key once and store it in
Codemagic; every build afterwards reuses the same certificate.

This is needed because Apple has never issued a certificate for this
account yet — hence the build errors:

    No matching profiles found for bundle identifier "com.okaymessaging"
    Cannot save Signing Certificates without certificate private key

## 1. Generate the private key

Run this **once**, anywhere you have a terminal. On Windows use **Git Bash**
(installed with Git); on macOS/Linux any terminal works:

    ssh-keygen -t rsa -b 2048 -m PEM -f cert_key -q -N ""

That writes a file named `cert_key` in the current folder. It is a normal
text file — open it with Notepad or any editor. It starts with:

    -----BEGIN RSA PRIVATE KEY-----

> No OpenSSL? Codemagic can also generate one for you:
> Team settings → Code signing identities → iOS certificates → Generate.

## 2. Add it to Codemagic

1. Open your app in Codemagic → **Environment variables**
2. Variable name: `CERTIFICATE_PRIVATE_KEY`
3. Value: paste the **entire** contents of `cert_key`, including the
   `-----BEGIN…` and `-----END…` lines
4. Group: leave blank (the workflow reads it directly)
5. Tick **Secure** so it is encrypted and never printed in build logs
6. Click **Add**

## 3. Run the `ios-release` workflow

On the first run Codemagic will:

1. Create the iOS distribution certificate (using this key)
2. Create the App Store provisioning profile for `com.okaymessaging`
3. Install both, build the IPA, and upload it to TestFlight

Both appear afterwards in the Apple Developer portal under
Certificates, Identifiers & Profiles. Later builds reuse them.

## Keep the key

Store `cert_key` somewhere safe (a password manager). If you lose it you
can't renew that certificate — you'd revoke it in the Apple portal and
generate a new key. Never commit it to the repository.

## If it still fails

The API key needs permission to create certificates. Check
App Store Connect → Users and Access → Integrations → your key's
**Access** column reads **App Manager**. A Developer-role key can
authenticate but cannot issue certificates.
