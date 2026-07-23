# NoPayloadDB Belle II HSF chart

This chart deploys the Belle II HSF NoPayloadDB service on Kubernetes or
OpenShift. Kubernetes is the default platform and uses standard Ingress
resources. OpenShift uses ImageStreams and Routes.

Published chart versions are available from GitHub Container Registry. Replace
`OWNER` with the lowercase GitHub organization or user that owns the repository:

```bash
helm install npdb oci://ghcr.io/OWNER/charts/npdbchart --version 0.4.0
```

Publishing runs when this chart changes on `main`, and can also be started
manually in GitHub Actions. Increment `version` in `Chart.yaml` before publishing
a new release because OCI chart versions are immutable.

## Configure the chart

Copy `values.yaml` and override at least the public hosts, container images,
database connections, and credentials for the target environment.

The same image configuration is used on both platforms:

```yaml
images:
  django:
    repository: ghcr.io/bnlnpps/nopayloaddb
    tag: v5.1.0
    pullPolicy: IfNotPresent
```

Kubernetes workloads pull `repository:tag` directly. On OpenShift, the chart
imports that image into an ImageStream and points the workload at the imported
tag in the release namespace.

## Optional PostgreSQL

The chart can install PostgreSQL as part of the same Helm release. The
dependency is disabled by default, so existing external database deployments
continue to use `database.writer`, `database.reader1`, and `database.reader2`.

Fetch the dependency once after cloning the repository:

```bash
helm dependency build ./npdbchart_belle2_hsf_k8s
```

No Bitnami Helm repository setup is required; the locked dependency is fetched
from Bitnami's OCI registry.

Enable PostgreSQL and configure its credentials in the values file:

```yaml
postgresql:
  enabled: true
  auth:
    username: cdb
    password: test-password
    database: cdb
  primary:
    persistence:
      enabled: true
      size: 8Gi
```

When enabled, the chart automatically points the writer and both reader
connections at the bundled PostgreSQL Service. The external `database.*`
connection values are ignored. PgBouncer, when enabled, also connects to the
bundled database automatically.

The Django pod waits for its configured writer database to accept connections
before starting. When `django.migrations.enabled` is true, migrations run in a
separate init container after the database wait completes. The init container
generates the current `cdb_rest` migrations before applying them because the
default Django image does not include generated migration files.

To keep the password out of the values file, create a Secret in the release
namespace and point both PostgreSQL and the application workloads at it:

```bash
kubectl create secret generic npdb-postgresql-credentials \
  --namespace npdb \
  --from-literal=password='replace-with-a-strong-password'
```

```yaml
postgresql:
  enabled: true
  auth:
    username: cdb
    database: cdb
    existingSecret: npdb-postgresql-credentials
    secretKeys:
      userPasswordKey: password
```

The Secret must exist in the Helm release namespace before installation or
upgrade. PgBouncer cannot currently be enabled with this option because its
authentication file requires additional Secret handling.

For quick testing, the same configuration can be supplied on the command line:

```bash
helm upgrade --install npdb ./npdbchart_belle2_hsf_k8s \
  --namespace npdb-test \
  --create-namespace \
  --set postgresql.enabled=true \
  --set-string postgresql.auth.password='test-password' \
  --set django.migrations.enabled=true
```

## Kubernetes

Install the chart with its default Django backend:

```bash
helm upgrade --install npdb ./npdbchart_belle2_hsf_k8s \
  --namespace npdb \
  --create-namespace \
  --values /path/to/values.yaml
```

The chart creates a standard `networking.k8s.io/v1` Ingress with rules for
`hosts.api` and `hosts.files`.

For Traefik, set the ingress class and any controller-specific annotations in
the values file. No Traefik CRDs are required by the chart:

```yaml
ingress:
  enabled: true
  className: traefik
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
  tls:
    - secretName: npdb-tls
      hosts:
        - npdb.example.org
        - npdb-files.example.org
```

### Authenticated payload files

Payload-file access is read-only and unauthenticated by default. To validate
every `/dbstore` request with an OAuth bearer token and allow HTTP `PUT`
uploads, configure an IAM-compatible userinfo endpoint:

```yaml
nginx:
  podSecurityContext:
    fsGroup: 101

files:
  upload:
    enabled: true
  authentication:
    enabled: true
    userinfoUrl: https://iam.example.org/userinfo
```

NGINX forwards the request's `Authorization` header to the userinfo endpoint
and serves the request only when that endpoint returns a successful response.
Uploads cannot be enabled without authentication. The pod security context
must give the NGINX worker write access to the payload volume; group ID 101 is
used by the standard NGINX Alpine image.

## OpenShift

Select OpenShift explicitly:

```yaml
platform: openshift
```

The chart creates an ImageStream for NGINX and the selected backend, plus one
Route for each public host. Enabling PgBouncer also creates its ImageStream.
Route annotations and TLS settings are configurable:

```yaml
route:
  enabled: true
  annotations:
    haproxy.router.openshift.io/disable_cookies: "true"
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Allow
```

## Java backend

Select Java and provide an existing payload PVC:

```yaml
backend:
  type: java

storage:
  payload:
    existingClaim: payload-data
    subPath: ""
```

Alternatively, let the chart create a PVC. For example, an NFS provisioner
that exposes the `nfs-client` StorageClass can dynamically provision RWX
storage:

```yaml
backend:
  type: java

storage:
  payload:
    create: true
    storageClass: nfs-client
    size: 20Gi
    accessModes:
      - ReadWriteMany
```

Set either `existingClaim` or `create`, but not both. When `storageClass` is
empty, the cluster's default StorageClass is used. The values schema rejects
Java configurations that select neither option. With the Django backend,
NGINX continues to use `emptyDir` when neither option is selected.

## Migrating flat values

Chart version `0.2.0` intentionally replaces the previous flat values. There
are no compatibility aliases.

| Previous value | New value |
| --- | --- |
| `use_java` | `backend.type: django` or `java` |
| `use_pgbouncer` | `pgbouncer.enabled` |
| `use_ingress` | `platform` plus `ingress.enabled` or `route.enabled` |
| `domain`, `appname` | `hosts.api` as a complete hostname |
| `domain`, `appname_files` | `hosts.files` as a complete hostname |
| `*_docker_image` | `images.<component>.repository` and `.tag` |
| `dbhost_w`, `dbname_w`, `dbuser_w`, `dbpassword_w` | `database.writer.*` |
| `dbhost_r1`, `dbname_r1`, `dbuser_r1`, `dbpassword_r1` | `database.reader1.*` |
| `dbhost_r2`, `dbname_r2`, `dbuser_r2`, `dbpassword_r2` | `database.reader2.*` |
| `pvc_payload_server`, `subPath` | `storage.payload.*` |
| `exclude_node` | `scheduling.excludeNode` |
| `pgbouncer_node` | `pgbouncer.node` |
| `django_replicas` | `django.replicas` |
| `migrations_enabled` | `django.migrations.enabled` |
| `promtail_enabled` | `promtail.enabled` |
| `nginx_cache_control_value` | `nginx.cacheControl` |
| `cdb_*`, `permission_plugin_class`, `jwt_secret` | `cdb.*` |

The OpenShift `project` value was removed. The chart uses `.Release.Namespace`
for registry references and namespace-local Service names for internal traffic.
