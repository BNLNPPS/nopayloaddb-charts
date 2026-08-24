# Deploying the b2testpsql PostgreSQL Cluster

This guide explains how to deploy the `b2testpsql` PostgreSQL cluster for the Belle II Conditions DB on OpenShift.

The setup consists of:

* A PostgreSQL **primary**
* A PostgreSQL **streaming replica**
* `postgres-exporter` for PostgreSQL metrics
* Promtail for log collection
* PostgreSQL 15.9 using the official `postgres:15.9` image

The guide covers:

* [Deploying to OpenShift](#deploying-to-openshift)
* [Verifying the deployment](#verifying-the-deployment)
* [What to expect during the first deployment](#what-to-expect-during-the-first-deployment)
* [Troubleshooting](#troubleshooting)

---

## The most important thing to get right

There is one easy mistake that can cause a deployment to look healthy while replication is actually broken:

**Always give `envsubst` an explicit list of variables to replace.**

Some of the Kubernetes manifests contain shell scripts. For example, the primary has a `postStart` hook and the replica has a seed init container.

Those scripts contain shell variables such as `$PGDATA_DIR` and `$HBA_FILE`.

If you run `envsubst` without specifying which variables should be replaced:

```bash
# ❌ Don't do this
envsubst < deployment_psql_server.yaml | oc apply -f -
```

`envsubst` tries to replace **every `$VAR` it finds**.

That includes variables that are supposed to be evaluated later, when the container is running. If those variables are not present in the environment where `envsubst` is executed, they are replaced with an empty string.

For example:

```sh
HBA_FILE="/pg_hba.conf"
if [ -f "" ]; then
```

The script still looks valid, so Kubernetes doesn't report an error. The pod can become Ready, but the replication rules are never added to `pg_hba.conf`.

Instead, explicitly tell `envsubst` which variables belong to deployment-time substitution:

```bash
# ✅ Only the deployment variables are substituted.
# Runtime shell variables remain untouched.
envsubst '${INSTANCE_NAME} ${NAMESPACE} ${POSTGRESQL_DATABASE}' \
  < deployment_psql_server.yaml | oc apply -f -
```

### Variables used by each manifest

| File                            | Variables to substitute                                                         |
| ------------------------------- | ------------------------------------------------------------------------------- |
| `deployment_psql_server.yaml`   | `${INSTANCE_NAME} ${NAMESPACE} ${POSTGRESQL_DATABASE}`                          |
| `statefulset_psql_replica.yaml` | `${NAMESPACE}`                                                                  |
| `secret_psql_credentials.yaml`  | `${NAMESPACE}`                                                                  |
| `secret_psql_exporter_dsn.yaml` | `${NAMESPACE} ${POSTGRESQL_DATABASE} ${POSTGRESQL_USER} ${POSTGRESQL_PASSWORD}` |
| `promtail-config.yaml`          | `${NAMESPACE}`                                                                  |
| `servicemonitor_postgres.yaml`  | `${NAMESPACE}`                                                                  |

One file deserves special attention: `statefulset_psql_replica.yaml`.

It contains `${POSTGRES_USER}` and `${POSTGRES_PASSWORD}`, but these are **runtime shell variables**, not deployment variables. Leave them untouched.

Note how close those names are to the deployment variables:

| Name | What it is |
| ------------------------------------------ | ---------------------------------------------------- |
| `POSTGRESQL_USER` / `POSTGRESQL_PASSWORD`   | deployment variables — you set these |
| `POSTGRES_USER` / `POSTGRES_PASSWORD`       | runtime variables — the container reads them from its own environment |

The difference is the `QL`. Don't export the short forms at all; the explicit `envsubst` list already protects you, and not setting them removes the temptation to add them to a variable list later.

### When the variables are needed

Only while rendering. `envsubst` reads them and writes out a finished manifest; after that the file contains plain values, and `oc apply` needs nothing set. If you render into files first and apply them the next day from a different shell, that works fine.

You don't have to set every variable for every file — only the ones in the table above. In practice it's simplest to export all five once, because `envsubst` only substitutes the variables you name in its argument and ignores the rest.

### Example: setting the variables before rendering

Export the variables first:

```bash
export NAMESPACE=belle2-cdb
export INSTANCE_NAME=b2testpsql-primary
export POSTGRESQL_DATABASE=conditions
export POSTGRESQL_USER=dbuser
export POSTGRESQL_PASSWORD=dbpassword
```

`secret_psql_credentials.yaml` in the repo looks like this — note the placeholder on the `namespace` line:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: b2testpsql-credentials
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  username: dbuser
  password: dbpassword
```

Render it:

```bash
envsubst '${NAMESPACE}' < secret_psql_credentials.yaml
```

The placeholder has been replaced with the exported value, and everything else is unchanged:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: b2testpsql-credentials
  namespace: belle2-cdb
type: Opaque
stringData:
  username: dbuser
  password: dbpassword
```

From there you can either pipe it straight to the cluster:

```bash
envsubst '${NAMESPACE}' < secret_psql_credentials.yaml | oc apply -f -
```

or write it to a file, inspect it, and apply it afterwards:

```bash
envsubst '${NAMESPACE}' < secret_psql_credentials.yaml > /tmp/secret-credentials.yaml
oc apply -f /tmp/secret-credentials.yaml
```

Write rendered files somewhere outside the repository. A rendered `secret_psql_exporter_dsn.yaml` contains the database password in plaintext, and it should never be committed.

### An unset variable fails silently

This is the same trap as the one above, in a different disguise. `envsubst` replaces unset variables with an empty string and never warns.

Forget to export `NAMESPACE` and you get:

```yaml
metadata:
  name: b2testpsql-credentials
  namespace:
```

No error. The resource then lands in whatever namespace your current context happens to point at, or fails much later with a message that says nothing about the real cause.

Before applying, confirm the substitutions actually happened:

```bash
envsubst '${INSTANCE_NAME} ${NAMESPACE} ${POSTGRESQL_DATABASE}' \
  < deployment_psql_server.yaml | grep -n 'namespace:'
```

Every line should name your namespace. A blank means a variable wasn't exported.

---

## Deploying to OpenShift

### 1. Set the database credentials

Before deploying, update `secret_psql_credentials.yaml`.

The file currently contains:

```text
dbuser / dbpassword
```

Those values should be changed before using the deployment in a real environment.

The credentials you export locally must match the values used by the Secret.

For example:

```bash
export NAMESPACE=belle2-cdb
export INSTANCE_NAME=b2testpsql-primary
export POSTGRESQL_DATABASE=conditions
export POSTGRESQL_USER=dbuser
export POSTGRESQL_PASSWORD=dbpassword
```

The username and password matter in two places:

1. PostgreSQL uses them when creating the database/user.
2. `postgres-exporter` uses them to connect to PostgreSQL.

If the values don't match, PostgreSQL itself may work normally, but the exporter will fail to collect metrics.

### 2. Apply the manifests

Apply the manifests in the following order:

```bash
envsubst '${NAMESPACE}' \
  < secret_psql_credentials.yaml | oc apply -f -

envsubst '${NAMESPACE} ${POSTGRESQL_DATABASE} ${POSTGRESQL_USER} ${POSTGRESQL_PASSWORD}' \
  < secret_psql_exporter_dsn.yaml | oc apply -f -

envsubst '${NAMESPACE}' \
  < promtail-config.yaml | oc apply -f -

envsubst '${INSTANCE_NAME} ${NAMESPACE} ${POSTGRESQL_DATABASE}' \
  < deployment_psql_server.yaml | oc apply -f -

envsubst '${NAMESPACE}' \
  < statefulset_psql_replica.yaml | oc apply -f -
```

If you're unsure whether `envsubst` is going to modify something it shouldn't, render the file first and inspect it:

```bash
envsubst '${INSTANCE_NAME} ${NAMESPACE} ${POSTGRESQL_DATABASE}' \
  < deployment_psql_server.yaml | grep HBA_FILE
```

You should still see:

```text
HBA_FILE="$PGDATA_DIR/pg_hba.conf"
```

If `$PGDATA_DIR` has disappeared or been replaced with an empty value, stop there and fix the `envsubst` command.

### A note about `INSTANCE_NAME`

`INSTANCE_NAME` controls the StatefulSet and container name.

The pod labels and Service selectors, however, are fixed to:

```yaml
app: b2testpsql-primary
```

The replica also connects to:

```text
b2testpsql-primary.${NAMESPACE}.svc.cluster.local
```

So changing `INSTANCE_NAME` is fine, but don't change the labels or Service selectors unless you also update all the places that depend on them.

### Redeploying after a failed installation

If `initdb` fails, the PVC may contain a partially initialized PostgreSQL data directory.

In that situation, deleting only the pod isn't enough. The new pod will mount the same PVC and encounter the old files again.

Delete the StatefulSet and its PVC:

```bash
oc delete statefulset b2testpsql-primary
oc delete pvc postgres-data-b2testpsql-primary-0
```

The next deployment will create a fresh data directory.

---

## Verifying the deployment

Once everything is running, `local-test/verify.sh` can be used to check the deployment.

It performs 14 checks covering things such as:

* UID and ownership
* The primary's `postStart` hook
* Service endpoints
* Streaming replication
* A real write/read test between the primary and replica
* Sidecar readiness

Run it against your current OpenShift context:

```bash
CONTEXT="" NAMESPACE=belle2-cdb DBU=<user> ./verify.sh
```

The UID check in section 1 should be skipped because OpenShift assigns the container UID through the SCC rather than using the value expected by the script.

### The most important replication check

If you only run one manual check, make it this one:

```bash
oc exec b2testpsql-primary-0 -- psql -U <user> -d conditions \
  -c "select client_addr, state, sync_state from pg_stat_replication;"
```

A healthy setup should show a row with:

```text
state = streaming
```

If there are **no rows**, the replica is not currently streaming from the primary.

The pod can still show `Running` and `Ready`, so pod status alone isn't enough to confirm that replication is working.

---

## What to expect during the first deployment

The first deployment can produce a couple of messages that look alarming but are normally expected.

### The replica may temporarily show `Init:Error`

During the first deployment, the replica's seed process needs two things:

1. The primary must be running.
2. The primary's `postStart` hook must have added the replication rules to `pg_hba.conf`.

Sometimes the replica starts before the primary has finished its setup.

The seed container doesn't retry internally, so it exits and Kubernetes restarts it with backoff.

You may see something like:

```text
restart 1  CrashLoopBackOff
restart 2  Error          (pg_basebackup: connection refused)
restart 3  Completed      ← self-heals, usually within ~45 seconds
```

So don't immediately assume the deployment is broken if the replica briefly goes through `Init:Error`.

### `primary_conninfo` may contain doubled quotes

You may notice something like:

```text
primary_conninfo = 'user=... host=''b2testpsql-primary.belle2-cdb.svc.cluster.local'' ...'
```

This is PostgreSQL's normal escaping of the value.

The hostname contains a hyphen, so PostgreSQL escapes the value when displaying it.

The replica parses the value correctly.

**Don't manually edit or "fix" the doubled quotes.**

---

# Troubleshooting

## `initdb: error: could not change permissions of directory ... Operation not permitted`

This usually means that `PGDATA` is pointing directly at the root of the mounted volume.

OpenShift runs containers with an arbitrary UID. The PVC mount itself may still be owned by `root`, while PostgreSQL's `initdb` needs to create and manage a directory with restrictive permissions.

The solution is to point `PGDATA` at a subdirectory of the mounted volume:

```yaml
- name: PGDATA
  value: /var/lib/postgresql/data/pgdata
```

PostgreSQL can then create and own the `pgdata` directory itself.

You may also see messages such as:

```text
chmod: changing permissions of ... Operation not permitted
```

These messages are not necessarily fatal. The image's entrypoint handles those commands with `|| :`.

The important error is the `initdb:` error that follows.

---

## `mkdir: cannot create directory ... Permission denied`

This is a different issue.

Here, the storage class may not be applying the expected `fsGroup`, meaning the mounted volume isn't writable by the group assigned to the pod.

This is commonly seen with storage systems such as CephFS and Manila.

Check the permissions on the mounted directory:

```bash
oc exec b2testpsql-primary-0 -- \
  stat -c '%A %u %g' /var/lib/postgresql/data
```

Ideally, you should see something similar to:

```text
drwxrwsr-x 0 <fsGroup>
```

If you instead see:

```text
drwxr-xr-x 0 0
```

the volume is not getting the expected group permissions.

---

## `pg_basebackup: FATAL: no pg_hba.conf entry for replication connection`

This means the replica tried to connect to the primary, but PostgreSQL didn't find a matching replication rule in `pg_hba.conf`.

The most common cause is the `envsubst` issue described earlier.

Check the primary's `pg_hba.conf`:

```bash
oc exec b2testpsql-primary-0 -- \
  grep replication /var/lib/postgresql/data/pgdata/pg_hba.conf
```

You should see both rules:

```text
host replication all 0.0.0.0/0 scram-sha-256
host replication all ::/0 scram-sha-256
```

If they're missing, check the rendered `deployment_psql_server.yaml` and make sure the `postStart` shell variables were not removed by `envsubst`.

---

## The replica is Ready, but `pg_stat_replication` is empty

This is an important case because the replica can look healthy even though it isn't actually replicating.

If `pg_basebackup` runs without the `-R` option, the replica is seeded with the primary's data but doesn't get the `primary_conninfo` configuration required to continue streaming WAL.

Check it with:

```bash
oc exec b2testpsql-replica-0 -c postgres -- \
  psql -U <user> -d conditions -tAc "show primary_conninfo;"
```

If this returns nothing, the replica doesn't know where its primary is.

The fix is to make sure the seed command uses `-R`, then delete the replica PVC so that it can seed again from scratch.

---

## Services have no endpoints

This usually means the Service selector and the pod labels don't match.

Both should use:

```yaml
app: b2testpsql-primary
```

Check the Service:

```bash
oc get svc b2testpsql-primary \
  -o jsonpath='{.spec.selector}'
```

Then check the pod:

```bash
oc get pod b2testpsql-primary-0 \
  -o jsonpath='{.metadata.labels}'
```

If the values don't match, Kubernetes won't add the pod to the Service endpoints.

---

## The exporter is running, but no metrics are available

If `postgres-exporter` is Ready but metrics are missing, check the credentials first.

The database username comes from `secret_psql_credentials.yaml`, while the exporter DSN is generated using:

```text
${POSTGRESQL_USER}
```

Make sure these refer to the same PostgreSQL user.

A mismatch can leave PostgreSQL completely healthy while the exporter fails to authenticate.

---

## Pods are rejected by Pod Security Admission

If the namespace uses:

```text
enforce=restricted
```

containers generally need settings such as:

```yaml
allowPrivilegeEscalation: false
```

and:

```yaml
capabilities:
  drop:
    - ALL
```

These settings aren't explicitly present in the manifests because OpenShift's `restricted-v2` SCC normally injects the required security settings.

If Pod Security Admission is also being enforced on top of SCC, however, these fields may need to be added explicitly.

---

## Quick sanity check

After deployment, the following three checks give a good indication that the cluster is healthy:

```bash
# 1. Pods are running
oc get pods

# 2. Services have endpoints
oc get endpoints

# 3. The replica is actually streaming
oc exec b2testpsql-primary-0 -- \
  psql -U <user> -d conditions \
  -c "select client_addr, state, sync_state from pg_stat_replication;"
```

For the third check, you want to see:

```text
state
-------
streaming
```

If you see that, the most important part of the primary → replica setup is working.
