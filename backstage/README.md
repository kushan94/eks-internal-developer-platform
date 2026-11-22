# Backstage

The platform's developer portal, built from the [Backstage](https://backstage.io) scaffold. It reads the catalog in [`catalog/`](../catalog) and has one software template, [`templates/webservice`](templates/webservice), which opens a pull request that adds a `WebService` and its catalog entry.

- **In the cluster:** runs at `https://backstage.<platform domain>` with GitHub sign-in, from the image built by the Backstage image workflow. Setup is in the root [README](../README.md#developer-portal) and [ADR 0010](../docs/adr/0010-backstage-in-cluster.md). Replicas start one at a time ([ADR 0028](../docs/adr/0028-backstage-serialized-startup.md)).
- **On your laptop:** needs Node.js 24 and Corepack, and a GitHub CLI login.

```sh
corepack enable
yarn install
make -C .. backstage   # http://localhost:3000
```

`make backstage` passes your GitHub CLI token to Backstage, which can reach all your repositories, so keep it on your own machine. `make test-template` renders the template and validates the result, and `make test-backstage` tests the launcher against a real Postgres.
