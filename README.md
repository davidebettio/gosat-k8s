# gosat-k8s — Kubernetes Deployment

Deploy dell'intera piattaforma GoSat su Kubernetes con Helmfile.

## Prerequisiti

- [Docker](https://docs.docker.com/get-docker/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/) 3.x
- [Helmfile](https://github.com/helmfile/helmfile#installation) v1.4+
- [helm-diff plugin](https://github.com/databus23/helm-diff): `helm plugin install https://github.com/databus23/helm-diff`

## Struttura

```
gosat-k8s/
├── helmfile.yaml.gotmpl                 # Orchestrator principale (Helmfile v1)
├── build.sh                             # Build di tutte le immagini Docker
├── install-operators.sh                 # Installa OLM + RabbitMQ operator (una tantum)
├── secrets-template.yaml                # Template secrets (da personalizzare)
│
├── charts/
│   ├── gosat-service/                   # Helm chart generico per tutti i microservizi
│   ├── mongodb-community/               # MongoDBCommunity CR (replica set)
│   ├── mongodb-olm/                     # MongoDB operator via OLM Subscription
│   └── rabbitmq-cluster/                # RabbitmqCluster CR
│
├── dockerfiles/
│   ├── Dockerfile.node                  # Per servizi Node.js/TypeScript
│   ├── Dockerfile.go                    # Per gosat-server (Go, cross-compilation arm64/amd64)
│   └── Dockerfile.web                   # Per gosat-web (Vue.js SPA → nginx)
│
├── values/                              # Values per-servizio (personalizzabili)
│   ├── gosat-api.yaml.gotmpl
│   ├── gosat-dispatcher.yaml.gotmpl
│   ├── gosat-server.yaml.gotmpl
│   ├── gosat-web.yaml.gotmpl
│   ├── gosat-sms.yaml.gotmpl
│   ├── gosat-caller.yaml.gotmpl
│   ├── gosat-geocoder.yaml.gotmpl
│   ├── gosat-shortener.yaml.gotmpl
│   ├── gosat-telegram-bot.yaml.gotmpl
│   ├── mongodb.yaml.gotmpl             # MongoDB replica set config
│   ├── mongodb-operator.yaml.gotmpl    # MongoDB OLM operator config
│   ├── redis.yaml.gotmpl               # Valkey (Redis-compatible)
│   ├── rabbitmq.yaml.gotmpl            # RabbitMQ cluster config
│   ├── opensearch.yaml.gotmpl          # OpenSearch cluster config
│   ├── opensearch-operator.yaml.gotmpl # OpenSearch operator config
│   └── ingress-nginx.yaml.gotmpl       # Ingress controller config
│
└── environments/
    ├── minikube/values.yaml             # Override per dev locale (arm64)
    └── production/values.yaml           # Override per DigitalOcean (amd64)
```

## Infrastruttura

Nessuna dipendenza da Bitnami. Tutti i componenti usano operator/chart ufficiali con immagini arm64 native:

| Componente | Operator/Chart | Immagine |
|---|---|---|
| **MongoDB** | [mongodb-kubernetes](https://github.com/mongodb/mongodb-kubernetes) via OLM | `mongo` (ufficiale) |
| **Redis** | [Valkey](https://valkey.io/valkey-helm/) (Redis-compatible) | `valkey/valkey` |
| **RabbitMQ** | [cluster-operator](https://github.com/rabbitmq/cluster-operator) | `rabbitmq` (ufficiale) |
| **OpenSearch** | [opensearch-k8s-operator](https://github.com/opensearch-project/opensearch-k8s-operator) | `opensearchproject/opensearch` |
| **Ingress** | [ingress-nginx](https://kubernetes.github.io/ingress-nginx) | — |

## Quick Start — Minikube (sviluppo locale)

```bash
# 1. Avvia minikube con risorse adeguate
minikube start --cpus=4 --memory=8192 --driver=docker

# 2. Abilita addon ingress
minikube addons enable ingress

# 3. Installa gli operator (una tantum per cluster)
cd gosat-k8s
./install-operators.sh

# 4. Punta docker al daemon di minikube
eval $(minikube docker-env)

# 5. Build immagini (arm64 nativo, veloce)
./build.sh --dev

# 6. Crea namespace e secrets
kubectl create namespace gosat
kubectl -n gosat apply -f secrets.yaml

# 7. Deploy
helmfile -e minikube sync

# 8. Accesso (aggiungi a /etc/hosts)
echo "$(minikube ip) gosat.local" | sudo tee -a /etc/hosts

# 9. Apri nel browser
open http://gosat.local
```

## Deploy — DigitalOcean (produzione)

### Setup iniziale

```bash
# 1. Crea cluster DOKS
doctl kubernetes cluster create gosat-prod \
  --region fra1 \
  --size s-4vcpu-8gb \
  --count 3

# 2. Configura kubectl
doctl kubernetes cluster kubeconfig save gosat-prod

# 3. Crea container registry
doctl registry create gosat
doctl registry login

# 4. Autorizza il cluster a pullare dal registry
doctl registry kubernetes-manifest | kubectl apply -f -

# 5. Installa gli operator
cd gosat-k8s
./install-operators.sh
```

### Build e Deploy

```bash
# 1. Build + push immagini (amd64 per produzione)
REGISTRY=registry.digitalocean.com/gosat ./build.sh --prod v1.0.0

# 2. Crea secrets (personalizza prima!)
cp secrets-template.yaml secrets.yaml
# Modifica secrets.yaml con i valori reali
kubectl create namespace gosat
kubectl -n gosat apply -f secrets.yaml

# 3. Deploy
helmfile -e production sync

# 4. Setup DNS: punta web.gosat.it all'IP del LoadBalancer
kubectl -n ingress-nginx get svc
```

### TLS con cert-manager

```bash
# Installa cert-manager
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true

# Crea ClusterIssuer Let's Encrypt
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@gosat.it
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
```

## Build immagini

```bash
# Dev locale (arm64 nativo su Apple Silicon, senza push)
./build.sh --dev

# Produzione (amd64, push a registry)
REGISTRY=registry.digitalocean.com/gosat ./build.sh --prod v1.0.0

# Singola immagine
docker build --platform linux/arm64 \
  -f gosat-k8s/dockerfiles/Dockerfile.node \
  --build-arg SERVICE_DIR=gosat-api \
  -t gosat/gosat-api:latest .

# Con piattaforma esplicita
PLATFORM=linux/amd64 ./build.sh v1.0.0
```

## Comandi utili

```bash
# Preview delle modifiche
helmfile -e minikube diff

# Deploy solo di un servizio
helmfile -e minikube -l name=gosat-api sync

# Deploy solo infrastruttura
helmfile -e minikube -l name=mongodb sync
helmfile -e minikube -l name=redis sync
helmfile -e minikube -l name=rabbitmq sync

# Logs
kubectl -n gosat logs -f deployment/gosat-api-gosat-service

# Scale
kubectl -n gosat scale deployment/gosat-api-gosat-service --replicas=3

# Port forward per debug
kubectl -n gosat port-forward svc/gosat-api-gosat-service 6001:6001
kubectl -n gosat port-forward svc/redis 6379:6379
kubectl -n gosat port-forward svc/rabbitmq 5672:5672

# Status completo
helmfile -e minikube status
kubectl -n gosat get pods,svc,ingress

# Distruggi tutto
helmfile -e minikube destroy
```

## Architettura su K8s

```
Internet
  │
  ├─ HTTPS :443 ──→ Ingress-Nginx
  │                   ├─ /           → gosat-web (nginx static)
  │                   ├─ /api        → gosat-api (Node.js)
  │                   ├─ /socket.io  → gosat-api (WebSocket)
  │                   ├─ /geocoder   → gosat-geocoder
  │                   ├─ /l          → gosat-shortener
  │                   └─ /sms        → gosat-sms
  │
  └─ TCP :30060 ──→ Ingress-Nginx TCP proxy → gosat-server (Go)

Internal:
  gosat-server ──→ RabbitMQ (operator) ──→ gosat-dispatcher
                                       ──→ gosat-sms
                                       ──→ gosat-caller

  All services ──→ MongoDB (operator, ReplicaSet)
               ──→ Valkey/Redis
               ──→ OpenSearch (operator)
```

## Differenze tra ambienti

| Aspetto | Minikube | DigitalOcean |
|---|---|---|
| Registry | `gosat` (locale) | `registry.digitalocean.com/gosat` |
| Image pull | `Never` (buildate in minikube) | `IfNotPresent` |
| Platform | `linux/arm64` (Apple Silicon) | `linux/amd64` |
| Ingress | minikube addon | Helm chart + LoadBalancer |
| TLS | No | Si (cert-manager + Let's Encrypt) |
| MongoDB | 1 replica, 5Gi | 3 repliche, 100Gi |
| Dominio | `gosat.local` | `web.gosat.it` |
