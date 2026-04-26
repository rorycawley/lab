# How this POC maps to production

| POC component | Production equivalent | What this derisks |
|---|---|---|
| Docker `event-postgres` | Patroni PostgreSQL event-store cluster on VMs | App and Flyway can reach a database outside Kubernetes. |
| Docker `read-postgres` | Patroni PostgreSQL read-store cluster on VMs | App and Flyway can manage separate event/read databases. |
| `ExternalName` Services | DNS records for HAProxy VIPs | Kubernetes workloads can use stable names for VM-hosted databases. |
| Flyway Kubernetes Jobs | Argo CD PreSync migration Jobs | Migrations run as controlled one-off jobs before app deployment. |
| Python API Deployment | .NET modular monolith Deployment | App pods can connect to VM-hosted PostgreSQL directly. |
| `flyway_schema_history` | Same in production DBs | Applied migrations are tracked and not rerun. |

## Production release sequence

```text
Vendor CI builds:
  - app image
  - migration image or migration scripts

Customer Harbor imports artifacts.
Customer GitOps repo is updated.
Argo CD sync starts.
Flyway PreSync Jobs run against HAProxy write VIPs.
If migration succeeds, app is deployed.
If migration fails, app deployment stops.
```

## POC limitation

The POC does not test Patroni failover, HAProxy routing, backup/restore, Vault, Harbor, Argo CD, Rancher HA, or Marten itself.

It deliberately tests only the release-critical database migration shape:

```text
Kubernetes Job -> external PostgreSQL -> schema change tracked by Flyway
Kubernetes app -> external PostgreSQL -> normal runtime access
```
