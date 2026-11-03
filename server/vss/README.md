# BitKiss VSS server

Encrypted backup of each wallet's Lightning channel state, so that
"reinstall + 12 words" brings the channels back, not only the on-chain coins.

What the server sees: opaque encrypted blobs, keyed by a public key the app
derives from the wallet seed. It cannot read channel data or move funds.

## Deploy (on the server)

    mkdir -p /root/vss && cd /root/vss
    # copy docker-compose.yml, setup.sh and Caddyfile.snippet here, then:
    bash setup.sh

Then add the Caddyfile.snippet block to the Caddyfile and reload Caddy.
DNS: `vss.bitkiss.eu  A  162.35.161.17`.

## Check

    curl -s https://vss.bitkiss.eu/vss/getObject -X POST   # expect an auth error, not a connection error
    docker logs vss-server --tail 20

## Auth

Signature auth (vss-server default): every request carries a secp256k1
signature in the Authorization header; the signing key is derived from the
wallet seed inside BitKiss. Data is additionally encrypted on the phone before upload.
