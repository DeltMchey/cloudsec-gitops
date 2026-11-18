# Intentionally no backend block: CI initializes with `terraform init
# -backend=false`, so no state backend, credentials, locking service, or remote
# state network access is configured in the W3 offline-plan gate.
# W9 execution must make a separate, reviewed state-backend decision first.
