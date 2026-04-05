# Root Keys

Store repository root public keys here using the filename pattern:

- `<rootKeyId>.pem`

Example:

- `emma-root-2026.pem`

The runtime verifies repository delegation metadata using the matching root key file referenced by `rootKeyId`.
