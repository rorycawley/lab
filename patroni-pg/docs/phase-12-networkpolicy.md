# Phase 12: NetworkPolicy


Phase 12 turns the allowed flows from Phase 0 into Kubernetes NetworkPolicies and
proves that unselected Pods are denied at the network layer, not only at Vault
or PostgreSQL auth.

Goal:

```text
Default-deny ingress and egress in the demo and vault namespaces, then allow
only the contracted flows. A random Pod in either namespace cannot reach Vault
or PostgreSQL on the network even if it forges identity at higher layers.
```

Allowed flows enforced by this phase:

```text
demo Pods labeled app.kubernetes.io/part-of=vault-postgres-security-demo
  -> vault/vault on TCP/8200
demo/python-postgres-demo
  -> host PostgreSQL on TCP/5432
vault/vault
  -> host PostgreSQL on TCP/5432
all Pods in demo and vault
  -> kube-system DNS on UDP/53 and TCP/53
```

Operational flows that must remain open:

```text
kubelet -> demo/python-postgres-demo on TCP/8080  (liveness and readiness probes)
Kubernetes API server -> vault/vault-agent-injector on TCP/8443  (admission webhook)
vault/vault and vault/vault-agent-injector -> Kubernetes API server  (TokenReview, watches)
```

This phase creates:

```text
k8s/15-networkpolicies.yaml
NetworkPolicy: demo/default-deny-all
NetworkPolicy: demo/allow-dns
NetworkPolicy: demo/demo-egress-vault
NetworkPolicy: demo/demo-egress-postgres
NetworkPolicy: demo/app-ingress-http
NetworkPolicy: vault/default-deny-all
NetworkPolicy: vault/allow-dns
NetworkPolicy: vault/vault-ingress-demo
NetworkPolicy: vault/vault-egress-apiserver-and-postgres
NetworkPolicy: vault/vault-injector-webhook
```

Acceptance criteria:

- default-deny ingress and egress are enforced in namespace `demo`
- default-deny ingress and egress are enforced in namespace `vault`
- DNS to kube-system is allowed for every Pod in `demo` and `vault`
- `demo/python-postgres-demo` can still reach `vault/vault` on TCP/8200
- `demo/python-postgres-demo` can still reach PostgreSQL on TCP/5432
- `vault/vault` can still reach PostgreSQL on TCP/5432
- `vault/vault` can still reach the Kubernetes API server for TokenReview
- `vault/vault-agent-injector` can still receive admission webhook calls
- the Vault Agent sidecar in the Python app Pod still renders `/vault/secrets/db-creds`
- a Pod in `demo` without the demo's `part-of` label cannot reach `vault/vault:8200`
- a Pod in `demo` that is not `python-postgres-demo` cannot reach PostgreSQL on TCP/5432
- the denied test Pod can still resolve cluster DNS, so denials are proven at L4

Important limitations of this phase:

```text
PostgreSQL runs in Docker Compose on host.rancher-desktop.internal, outside the
cluster. NetworkPolicy cannot select a host endpoint by namespace or pod, so
egress to PostgreSQL is expressed as TCP/5432 to an ipBlock and is restricted
to the Pods that legitimately need it. PostgreSQL cannot be defended with
ingress NetworkPolicy from inside the cluster.

The Vault Agent Injector admission webhook (TCP/8443) accepts ingress from any
IP. The Kubernetes API server's source IP varies by distribution, so a tighter
selector is left to the Phase 16 IaC track.

NetworkPolicy enforcement requires a CNI that supports it. Rancher Desktop
ships k3s with kube-router, which enforces NetworkPolicy by default. On a
cluster whose CNI does not enforce policy, these manifests apply cleanly but do
not actually deny anything.
```

Run Phase 12:

```sh
make netpol
```

Verify only NetworkPolicies:

```sh
make verify-netpol
```

