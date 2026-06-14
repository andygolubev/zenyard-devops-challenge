CLUSTER_NAME ?= zenyard
NAMESPACE ?= zenyard
RELEASE_NAME ?= zenyard
CHART_PATH ?= charts/zenyard
LOCAL_VALUES ?= charts/zenyard/values-local.yaml
IMAGE ?= zenyard-api:local
INGRESS_URL ?= http://localhost:8080
GRAFANA_PORT ?= 3000

# GCP deployment configuration — set GCP_HOST to your VM public IP
GCP_IMAGE_NAME  ?= zenyard-api
GCP_IMAGE_TAG   ?= gcp
GCP_IMAGE       ?= $(GCP_IMAGE_NAME):$(GCP_IMAGE_TAG)
GCP_IMAGE_TAR   ?= /tmp/zenyard-api-gcp.tar
GCP_VALUES      ?= charts/zenyard/values-gcp.yaml
GCP_INVENTORY   ?= ansible/inventory.gcp.ini
GCP_HOST        ?=
GCP_USER        ?= ubuntu
GCP_SSH_KEY     ?= $(HOME)/.ssh/id_rsa
GCP_SSH          = ssh -i $(GCP_SSH_KEY) -o StrictHostKeyChecking=no -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=10 $(GCP_USER)@$(GCP_HOST)
GCP_SCP          = scp -i $(GCP_SSH_KEY) -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=10
GCP_KUBECONFIG   = /home/$(GCP_USER)/.kube/config
GCP_INGRESS_URL ?= http://$(GCP_HOST)
GCP_GRAFANA_PORT ?= 3000
# Sealed Secrets controller (must match ansible/group_vars/gcp.yml)
SS_CONTROLLER_NS   ?= sealed-secrets
SS_CONTROLLER_NAME ?= sealed-secrets
SEALED_SECRETS_DIR ?= sealed-secrets/gcp

.PHONY: install-local-tools-help create-local delete-local restart-local verify-local build-image-local load-image-local helm-deps deploy-local redeploy-local uninstall-local test-local generate-slow-query port-forward-grafana logs-app logs-postgres local-info
.PHONY: gcp-bootstrap gcp-verify-k3s gcp-build-image gcp-load-image gcp-helm-deps gcp-deploy gcp-redeploy gcp-test gcp-stress gcp-port-forward-grafana gcp-logs-app gcp-logs-postgres gcp-generate-slow-query gcp-info gcp-sealed-secrets-install gcp-seal-secrets gcp-apply-sealed-secrets

install-local-tools-help:
	@printf '%s\n' 'Required local tools:'
	@printf '%s\n' '  Docker: https://docs.docker.com/get-docker/'
	@printf '%s\n' '  k3d: https://k3d.io/'
	@printf '%s\n' '  kubectl: https://kubernetes.io/docs/tasks/tools/'
	@printf '%s\n' '  Helm: https://helm.sh/docs/intro/install/'
	@printf '%s\n' '  Make, curl, jq'

create-local:
	@command -v docker >/dev/null
	@command -v k3d >/dev/null
	@command -v kubectl >/dev/null
	@if k3d cluster list $(CLUSTER_NAME) >/dev/null 2>&1; then \
		printf '%s\n' 'Cluster $(CLUSTER_NAME) already exists'; \
	else \
		k3d cluster create $(CLUSTER_NAME) --servers 1 --agents 0 -p '8080:80@loadbalancer'; \
	fi
	@kubectl config use-context k3d-$(CLUSTER_NAME)
	@kubectl wait --for=condition=Ready node --all --timeout=180s
	@$(MAKE) verify-local

delete-local:
	@if command -v k3d >/dev/null && k3d cluster list $(CLUSTER_NAME) >/dev/null 2>&1; then \
		k3d cluster delete $(CLUSTER_NAME); \
	else \
		printf '%s\n' 'Cluster $(CLUSTER_NAME) does not exist'; \
	fi

restart-local: delete-local create-local

verify-local:
	@kubectl cluster-info
	@kubectl get nodes
	@kubectl wait --for=condition=Ready node --all --timeout=180s
	@kubectl get storageclass local-path
	@printf '%s\n' 'Waiting for metrics-server API...'
	@for i in $$(seq 1 24); do \
		if kubectl top nodes >/dev/null 2>&1; then \
			kubectl top nodes; \
			exit 0; \
		fi; \
		sleep 5; \
	done; \
	printf '%s\n' 'kubectl top nodes is not ready yet. See docs/troubleshooting.md for the local metrics-server fix.'; \
	exit 1

build-image-local:
	docker build -t $(IMAGE) app

load-image-local:
	k3d image import $(IMAGE) --cluster $(CLUSTER_NAME)

helm-deps:
	helm dependency update $(CHART_PATH)

deploy-local:
	helm upgrade --install $(RELEASE_NAME) $(CHART_PATH) \
		--namespace $(NAMESPACE) \
		--create-namespace \
		--values $(LOCAL_VALUES) \
		--set app.image.repository=$$(printf '%s' '$(IMAGE)' | cut -d: -f1) \
		--set app.image.tag=$$(printf '%s' '$(IMAGE)' | cut -s -d: -f2) \
		--server-side=false \
		--wait \
		--timeout 15m

redeploy-local: build-image-local load-image-local helm-deps deploy-local

uninstall-local:
	@if command -v helm >/dev/null && helm status $(RELEASE_NAME) --namespace $(NAMESPACE) >/dev/null 2>&1; then \
		helm uninstall $(RELEASE_NAME) --namespace $(NAMESPACE); \
	else \
		printf '%s\n' 'Release $(RELEASE_NAME) is not installed in namespace $(NAMESPACE)'; \
	fi

test-local:
	INGRESS_URL=$(INGRESS_URL) NAMESPACE=$(NAMESPACE) RELEASE_NAME=$(RELEASE_NAME) scripts/smoke-test-local.sh

generate-slow-query:
	NAMESPACE=$(NAMESPACE) RELEASE_NAME=$(RELEASE_NAME) scripts/generate-slow-query.sh

port-forward-grafana:
	@printf '%s\n' 'Grafana URL: http://localhost:$(GRAFANA_PORT)'
	@printf '%s\n' 'Username: admin'
	@printf '%s\n' 'Password: kubectl get secret -n $(NAMESPACE) zenyard-grafana -o jsonpath="{.data.admin-password}" | base64 -d'
	kubectl port-forward -n $(NAMESPACE) svc/zenyard-grafana $(GRAFANA_PORT):80

logs-app:
	kubectl logs -n $(NAMESPACE) -l app.kubernetes.io/component=api --tail=200 -f

logs-postgres:
	kubectl logs -n $(NAMESPACE) -l app.kubernetes.io/name=postgresql --tail=200 -f

local-info:
	@printf '%s\n' 'Cluster: $(CLUSTER_NAME)'
	@printf '%s\n' 'Namespace: $(NAMESPACE)'
	@printf '%s\n' 'Release: $(RELEASE_NAME)'
	@printf '%s\n' 'Ingress: $(INGRESS_URL)'
	@kubectl get nodes
	@kubectl get pods -n $(NAMESPACE) -o wide || true
	@kubectl get ingress -n $(NAMESPACE) || true

# ── GCP deployment ────────────────────────────────────────────────────────────
# Prerequisites: ansible/inventory.gcp.ini (copy from .example), GCP_HOST=<ip>
# Workflow: gcp-bootstrap → gcp-build-image → gcp-load-image → gcp-deploy → gcp-test

gcp-bootstrap:
	@[ -f $(GCP_INVENTORY) ] || { \
		printf '%s\n' 'Missing $(GCP_INVENTORY). Copy ansible/inventory.gcp.ini.example and fill in your VM details.'; \
		exit 1; \
	}
	ansible-playbook -i $(GCP_INVENTORY) ansible/playbook.yml --tags bootstrap
	ansible-playbook -i $(GCP_INVENTORY) ansible/playbook.yml --tags verify

gcp-verify-k3s:
	@[ -f $(GCP_INVENTORY) ] || { printf '%s\n' 'Missing $(GCP_INVENTORY).'; exit 1; }
	ansible-playbook -i $(GCP_INVENTORY) ansible/playbook.yml --tags verify

gcp-build-image:
	docker build --platform linux/amd64 -t $(GCP_IMAGE) app

gcp-load-image:
	@[ -n "$(GCP_HOST)" ] || { \
		printf '%s\n' 'Set GCP_HOST=<vm-ip>  (e.g. make gcp-load-image GCP_HOST=34.x.x.x)'; \
		exit 1; \
	}
	docker save $(GCP_IMAGE) -o $(GCP_IMAGE_TAR)
	$(GCP_SCP) $(GCP_IMAGE_TAR) $(GCP_USER)@$(GCP_HOST):/tmp/
	$(GCP_SSH) "sudo k3s ctr images import /tmp/zenyard-api-gcp.tar && sudo rm /tmp/zenyard-api-gcp.tar"
	rm -f $(GCP_IMAGE_TAR)
	@printf '%s\n' 'Image $(GCP_IMAGE) is now available in remote k3s containerd'

gcp-helm-deps:
	helm repo add bitnami https://charts.bitnami.com/bitnami || true
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
	helm repo add grafana https://grafana.github.io/helm-charts || true
	helm repo update
	helm dependency update $(CHART_PATH)

gcp-deploy:
	@[ -f $(GCP_INVENTORY) ] || { printf '%s\n' 'Missing $(GCP_INVENTORY).'; exit 1; }
	ansible-playbook -i $(GCP_INVENTORY) ansible/playbook.yml --tags deploy

# Install the Bitnami Sealed Secrets controller on the remote cluster (idempotent).
gcp-sealed-secrets-install:
	@[ -f $(GCP_INVENTORY) ] || { printf '%s\n' 'Missing $(GCP_INVENTORY).'; exit 1; }
	ansible-playbook -i $(GCP_INVENTORY) ansible/playbook.yml --tags ss-install

# Seal credentials against the remote controller; writes encrypted YAML to $(SEALED_SECRETS_DIR).
# Source values from env/args (or you are prompted): DB_USER, DB_PASSWORD,
# GRAFANA_ADMIN_USER, GRAFANA_ADMIN_PASSWORD. Plaintext is never written to the repo.
gcp-seal-secrets:
	@[ -n "$(GCP_HOST)" ] || { printf '%s\n' 'Set GCP_HOST=<vm-ip>  (e.g. make gcp-seal-secrets GCP_HOST=34.x.x.x)'; exit 1; }
	GCP_HOST=$(GCP_HOST) GCP_USER=$(GCP_USER) GCP_SSH_KEY=$(GCP_SSH_KEY) \
		NAMESPACE=$(NAMESPACE) \
		SS_CONTROLLER_NS=$(SS_CONTROLLER_NS) SS_CONTROLLER_NAME=$(SS_CONTROLLER_NAME) \
		OUT_DIR=$(SEALED_SECRETS_DIR) \
		scripts/seal-secrets-remote.sh

# Apply the committed SealedSecrets to the remote cluster (controller unseals them into Secrets).
gcp-apply-sealed-secrets:
	@[ -f $(GCP_INVENTORY) ] || { printf '%s\n' 'Missing $(GCP_INVENTORY).'; exit 1; }
	ansible-playbook -i $(GCP_INVENTORY) ansible/playbook.yml --tags ss-apply

gcp-redeploy: gcp-build-image gcp-load-image gcp-deploy

gcp-test:
	@[ -n "$(GCP_HOST)" ] || { printf '%s\n' 'Set GCP_HOST=<vm-ip>  (e.g. make gcp-test GCP_HOST=34.x.x.x)'; exit 1; }
	GCP_HOST=$(GCP_HOST) GCP_USER=$(GCP_USER) GCP_SSH_KEY=$(GCP_SSH_KEY) \
		NAMESPACE=$(NAMESPACE) RELEASE_NAME=$(RELEASE_NAME) \
		INGRESS_URL=$(GCP_INGRESS_URL) \
		scripts/smoke-test-remote.sh

gcp-stress:
	@[ -n "$(GCP_HOST)" ] || { printf '%s\n' 'Set GCP_HOST=<vm-ip>  (e.g. make gcp-stress GCP_HOST=34.x.x.x)'; exit 1; }
	GCP_HOST=$(GCP_HOST) GCP_USER=$(GCP_USER) GCP_SSH_KEY=$(GCP_SSH_KEY) \
		NAMESPACE=$(NAMESPACE) \
		CONCURRENCY=$(or $(CONCURRENCY),20) \
		TOTAL_REQUESTS=$(or $(TOTAL_REQUESTS),200) \
		scripts/stress-test-remote.sh

gcp-port-forward-grafana:
	@[ -n "$(GCP_HOST)" ] || { printf '%s\n' 'Set GCP_HOST=<vm-ip>'; exit 1; }
	@printf '%s\n' 'Grafana URL: http://localhost:$(GCP_GRAFANA_PORT)  (username: admin)'
	@printf '%s\n' 'Press Ctrl+C to stop.'
	ssh -i $(GCP_SSH_KEY) -o StrictHostKeyChecking=no -o BatchMode=yes \
		-o ServerAliveInterval=30 -o ServerAliveCountMax=10 \
		-L $(GCP_GRAFANA_PORT):localhost:$(GCP_GRAFANA_PORT) \
		$(GCP_USER)@$(GCP_HOST) \
		"KUBECONFIG=$(GCP_KUBECONFIG) kubectl port-forward -n $(NAMESPACE) svc/zenyard-grafana $(GCP_GRAFANA_PORT):80"

gcp-logs-app:
	@[ -n "$(GCP_HOST)" ] || { printf '%s\n' 'Set GCP_HOST=<vm-ip>'; exit 1; }
	$(GCP_SSH) "KUBECONFIG=$(GCP_KUBECONFIG) kubectl logs -n $(NAMESPACE) -l app.kubernetes.io/component=api --tail=200 -f"

gcp-logs-postgres:
	@[ -n "$(GCP_HOST)" ] || { printf '%s\n' 'Set GCP_HOST=<vm-ip>'; exit 1; }
	$(GCP_SSH) "KUBECONFIG=$(GCP_KUBECONFIG) kubectl logs -n $(NAMESPACE) -l app.kubernetes.io/name=postgresql --tail=200 -f"

gcp-generate-slow-query:
	@[ -n "$(GCP_HOST)" ] || { printf '%s\n' 'Set GCP_HOST=<vm-ip>'; exit 1; }
	$(GCP_SSH) "NAMESPACE=$(NAMESPACE) RELEASE_NAME=$(RELEASE_NAME) KUBECONFIG=$(GCP_KUBECONFIG) bash -s" \
		< scripts/generate-slow-query.sh

gcp-info:
	@[ -n "$(GCP_HOST)" ] || { printf '%s\n' 'Set GCP_HOST=<vm-ip>'; exit 1; }
	@printf '%s\n' '=== GCP Deployment Info ==='
	@printf 'Host:      %s\n' '$(GCP_HOST)'
	@printf 'Namespace: %s\n' '$(NAMESPACE)'
	@printf 'Release:   %s\n' '$(RELEASE_NAME)'
	@printf 'FastAPI:   %s\n' '$(GCP_INGRESS_URL)/healthz'
	@printf 'Grafana:   %s\n' 'make gcp-port-forward-grafana GCP_HOST=$(GCP_HOST)'
	$(GCP_SSH) "KUBECONFIG=$(GCP_KUBECONFIG) kubectl get nodes"
	$(GCP_SSH) "KUBECONFIG=$(GCP_KUBECONFIG) kubectl get pods -n $(NAMESPACE) -o wide" || true
	$(GCP_SSH) "KUBECONFIG=$(GCP_KUBECONFIG) kubectl get ingress -n $(NAMESPACE)" || true
