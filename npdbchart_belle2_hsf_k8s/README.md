# NoPayloadDB Belle II HSF chart

This chart deploys the Belle II HSF NoPayloadDB service on Kubernetes or
OpenShift. Kubernetes is the default platform and uses standard Ingress
resources. OpenShift uses ImageStreams and Routes.

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

The values schema rejects Java configurations without an existing claim.

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
