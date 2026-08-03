# Extra root CAs for the container build

Drop `.pem` / `.crt` files here to have the Docker build trust additional root
CAs. Needed on networks behind a TLS-intercepting proxy: the container does not
inherit the host's trust store, so `corepack`/`pnpm`/`pip` fail with
`UNABLE_TO_GET_ISSUER_CERT_LOCALLY` even though the host works fine.

Certificate files in this directory are gitignored. An empty directory is a
no-op, so the build works unchanged without one.

Export a root from the macOS System keychain with:

    security find-certificate -a -c "<CA common name>" -p \
      /Library/Keychains/System.keychain > docker-ca/corporate-root.pem

Verify it actually validates the chain before building:

    openssl s_client -connect registry.npmjs.org:443 \
      -CAfile docker-ca/corporate-root.pem </dev/null 2>/dev/null \
      | grep "Verify return code"
