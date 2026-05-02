# Kubernetes Network Zero-Trust Demo

A small learning project that shows restricted TLS communication between two
Python web apps running in different Kubernetes namespaces.

The goal is to make zero trust, least privilege, and defense in depth visible:

- `network-alpha` runs `alpha-app`, the only approved client.
- `network-beta` runs `beta-app`, the protected service.
- Both apps serve HTTPS.
- `beta-app` requires a client certificate signed by the demo CA.
- `beta-app` also checks the client certificate common name and only accepts
  `alpha.network-zero-trust.local`.
- Both namespaces start with default-deny ingress and egress policies.
- `alpha-app` gets egress only to Kubernetes DNS and `beta-app:8443`.
- `beta-app` gets ingress only from pods labelled `app=alpha-app` in
  `network-alpha`.
- Pods run as non-root, have no service account token mounted, drop Linux
  capabilities, and use a read-only root filesystem.

## Architecture

```text
operator
  |
  | kubectl port-forward service/alpha-app 8443:8443
  v
network-alpha / alpha-app
  - HTTPS server
  - client certificate CN=alpha.network-zero-trust.local
  - egress: DNS + beta-app:8443 only
  |
  | HTTPS + mTLS
  v
network-beta / beta-app
  - HTTPS server
  - requires client certificate from demo CA
  - authorizes only alpha.network-zero-trust.local
  - ingress: alpha-app pods only

network-alpha / denied-client
  - no app=alpha-app label
  - blocked by network-alpha egress policy before beta
  - also lacks an approved client identity if policy is not enforced
  x
  x HTTPS to beta-app:8443 denied
```

## Requirements

- Rancher Desktop or another local Kubernetes cluster with `NetworkPolicy`
  support
- `kubectl`
- `docker`
- `make`
- `openssl`
- `curl`
- `jq`

Network policies require CNI enforcement. If your local cluster does not
enforce them, the smoke test still proves the TLS identity layer rejects
unauthorised clients.

The image uses `imagePullPolicy: Never`. Rancher Desktop and Docker Desktop
usually work after `make build` because the cluster node uses the same Docker
image store. Kind and Minikube usually need an explicit image load first:

```sh
kind load docker-image network-zero-trust-app:demo
minikube image load network-zero-trust-app:demo
```

## Quick Start

```sh
make up
make test-all
make clean
```

The image tag and local forwarded port can be overridden when needed:

```sh
make up IMAGE=network-zero-trust-app:dev
make test-all LOCAL_PORT=9443
```

`make up` runs:

```text
make tls
make build
make k8s-base
make certs
make deploy
make verify
```

## Useful Targets

- `make up` - generate certificates, build the image, deploy apps and policies
- `make test` - run the smoke test against an already-forwarded alpha endpoint
- `make test-all` - run the smoke test with a temporary port-forward
- `make port-forward` - forward `https://localhost:8443` to `alpha-app`
- `make status` - show resources and recent app logs
- `make full-check` - run everything and always clean up
- `make clean` - delete namespaces, generated certs, logs, and local image
- `make check-local` - syntax-check Python and dry-run Kubernetes manifests

Useful variables:

- `IMAGE` - container image tag used by build, deploy, test pods, and cleanup
  (`network-zero-trust-app:demo` by default)
- `LOCAL_PORT` - local port used by `make port-forward` and `make test-all`
  (`8443` by default)

## What `make test-all` Proves

1. `alpha-app` is reachable over HTTPS through a local port-forward.
2. `alpha-app` can call `beta-app` over TLS using its client certificate.
3. `beta-app` sees the client identity as
   `alpha.network-zero-trust.local`.
4. A rogue pod in `network-alpha` that is not labelled `app=alpha-app` cannot
   complete a request to `beta-app`.
5. Logs contain `PEER_CALL_ALLOWED` on alpha and `IDENTITY_REQUEST` on beta.

After `make test-all`, collected logs are written to `./logs/alpha.log` and
`./logs/beta.log`.

## Manual Inspection

Start the lab:

```sh
make up
```

In one terminal:

```sh
make port-forward
```

In another:

```sh
curl -k https://localhost:8443/call-peer | jq .
```

You can also run the smoke test against that existing port-forward:

```sh
make test
```

The port-forward works even though the namespaces use default-deny ingress
policies because Kubernetes NetworkPolicy applies to pod network traffic, while
`kubectl port-forward` is carried through the kubelet.

Inspect the policies:

```sh
kubectl -n network-alpha describe networkpolicy
kubectl -n network-beta describe networkpolicy
```

Inspect the certificate identity observed by beta:

```sh
kubectl -n network-beta logs deployment/beta-app | jq .
```

## Troubleshooting

- `ErrImageNeverPull`: load the local image into the cluster node, then rerun
  `make deploy`. For Kind use `kind load docker-image
  network-zero-trust-app:demo`; for Minikube use `minikube image load
  network-zero-trust-app:demo`.
- TLS handshake failures after the lab has been sitting for a while: demo
  certificates expire after 30 days. Run `make clean && make up`.
- Rogue pod reaches beta on a local cluster: the CNI may not enforce
  NetworkPolicy. The mTLS identity check still demonstrates the second layer of
  defense.
- `make test` cannot connect to localhost: start `make port-forward` in another
  terminal first, or use `make test-all` to create a temporary port-forward.

## What This Does Not Show

- No service mesh, sidecar proxy, SPIFFE, or SPIRE.
- No Kubernetes Ingress controller or external load balancer.
- No certificate rotation. The demo uses one short-lived local CA.
- No production-grade identity validation. The server checks certificate CN for
  readability; modern systems should use SAN-based identity.

## Cleanup Guarantee

`make clean` removes and verifies removal of:

- Kubernetes namespaces `network-alpha` and `network-beta`
- local image `network-zero-trust-app:demo`
- generated certificates in `generated/`
- smoke-test logs in `logs/`
- `/tmp/network-zero-trust-pf.log`
