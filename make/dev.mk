MARIADB_OPERATOR_NAME ?= mariadb-operator
MARIADB_OPERATOR_NAMESPACE ?= default
MARIADB_OPERATOR_SA_PATH ?= /tmp/mariadb-operator/token
WATCH_NAMESPACE ?= ""
KUBEBUILDER_ASSETS ?= "$(shell $(ENVTEST) use $(KUBERNETES_VERSION) -p path)"

ENV ?= \
	RELATED_IMAGE_MARIADB=$(RELATED_IMAGE_MARIADB) \
	RELATED_IMAGE_MAXSCALE=$(RELATED_IMAGE_MAXSCALE) \
	RELATED_IMAGE_EXPORTER=$(RELATED_IMAGE_EXPORTER) \
	RELATED_IMAGE_EXPORTER_MAXSCALE=$(RELATED_IMAGE_EXPORTER_MAXSCALE) \
	MARIADB_GALERA_LIB_PATH=$(MARIADB_GALERA_LIB_PATH) \
	MARIADB_OPERATOR_IMAGE=$(IMG) \
	MARIADB_OPERATOR_NAME=$(MARIADB_OPERATOR_NAME) \
	MARIADB_OPERATOR_NAMESPACE=$(MARIADB_OPERATOR_NAMESPACE) \
	MARIADB_OPERATOR_SA_PATH=$(MARIADB_OPERATOR_SA_PATH) \
	MARIADB_DEFAULT_VERSION=$(MARIADB_DEFAULT_VERSION) \
	WATCH_NAMESPACE=$(WATCH_NAMESPACE) \
	KUBEBUILDER_ASSETS=$(KUBEBUILDER_ASSETS)

TEST_ARGS ?= --coverprofile=cover.out
TEST ?= $(ENV) $(GINKGO) $(TEST_ARGS) --timeout 30m

GOCOVERDIR ?= .

PPROF_ADDR ?= ":6060"

##@ Test

.PHONY: test
test: envtest ginkgo ## Run unit tests.
	$(TEST) ./api/... ./pkg/... ./internal/helmtest/... ./internal/webhook/...

.PHONY: test-int
test-int: envtest ginkgo ## Run integration tests.
	$(TEST) ./internal/controller/...

.PHONY: test-api
test-api: envtest ginkgo ## Run api unit tests.
	$(TEST) ./api/...

.PHONY: test-pkg
test-pkg: envtest ginkgo ## Run pkg unit tests.
	$(TEST) ./pkg/...

.PHONY: test-helm
test-helm: envtest ginkgo ## Run helm unit tests.
	$(TEST) ./internal/helmtest/...

.PHONY: test-webhook
test-webhook: envtest ginkgo ## Run webhook unit tests.
	$(TEST) ./internal/webhook/...

.PHONY: cover
cover: ## Generate and view coverage report.
	@$(GO) tool cover -html=cover.out -o=cover.html
	open cover.html

##@ Lint

.PHONY: lint
lint: golangci-lint ## Lint.
	$(GOLANGCI_LINT) run

##@ Release

.PHONY: release
release: goreleaser ## Test release locally.
	$(GORELEASER) release --snapshot --clean

##@ Run

RUN_FLAGS ?= --log-dev --log-level=info --log-time-encoder=iso8601
# RUN_FLAGS ?= --log-dev --log-level=info --log-time-encoder=iso8601 --pprof --pprof-addr=$(PPROF_ADDR)

.PHONY: run
run: lint ## Run a controller from your host.
	$(ENV) $(GO) run cmd/controller/*.go $(RUN_FLAGS)

WEBHOOK_FLAGS ?= --log-dev --log-level=debug --log-time-encoder=iso8601 \
	--ca-cert-path=$(CA_CERT) --cert-dir=$(WEBHOOK_PKI_DIR) \
	--validate-cert=false
.PHONY: webhook
webhook: lint cert-webhook ## Run a webhook from your host.
	$(GO) run cmd/controller/*.go webhook $(WEBHOOK_FLAGS)

# CERT_CONTROLLER_FLAGS ?= --log-dev --log-level=debug --log-time-encoder=iso8601 \
# 	--ca-lifetime=26280h --cert-lifetime=2160h --renew-before-percentage=33 --requeue-duration=5m
CERT_CONTROLLER_FLAGS ?= --log-dev --log-level=debug --log-time-encoder=iso8601 \
	--ca-lifetime=1h --cert-lifetime=1m --renew-before-percentage=33 --requeue-duration=30s
.PHONY: cert-controller
cert-controller: lint ## Run a cert-controller from your host.
	$(GO) run cmd/controller/*.go cert-controller $(CERT_CONTROLLER_FLAGS)

BACKUP_ENV ?= AWS_ACCESS_KEY_ID=mariadb-operator AWS_SECRET_ACCESS_KEY=Minio11!
BACKUP_COMMON_FLAGS ?= --path=backup --target-file-path=backup/0-backup-target.txt \
	--s3 --s3-bucket=backups --s3-endpoint=minio:9000 --s3-region=us-east-1 --s3-tls --s3-ca-cert-path=/tmp/pki/ca/tls.crt \
	--compression=gzip --log-dev --log-level=debug --log-time-encoder=iso8601

BACKUP_FLAGS ?= --max-retention=8h $(BACKUP_COMMON_FLAGS)
.PHONY: backup
backup: lint ## Run backup from your host.
	$(BACKUP_ENV) $(GO) run cmd/controller/*.go backup $(BACKUP_FLAGS)

RESTORE_FLAGS ?= --target-time=1970-01-01T00:00:00Z $(BACKUP_COMMON_FLAGS)
.PHONY: restore
restore: lint ## Run restore from your host.
	$(BACKUP_ENV) $(GO) run cmd/controller/*.go backup restore $(RESTORE_FLAGS)

.PHONY: local-dir
local-dir: ## Create config and state directories for local development.
	mkdir -p mariadb/config
	mkdir -p mariadb/state

POD_ENV ?= \
	CLUSTER_NAME=cluster.local  \
	POD_NAME=mariadb-galera-0 \
	POD_NAMESPACE=default \
	POD_IP=10.244.0.36  \
	MARIADB_NAME=mariadb-galera \
	MARIADB_ROOT_PASSWORD=MariaDB11! \
	MYSQL_TCP_PORT=3306 \
	KUBECONFIG=$(HOME)/.kube/config

INIT_FLAGS ?= $(RUN_FLAGS) --config-dir=mariadb/config --state-dir=mariadb/state
.PHONY: init
init: local-dir ## Run init from your host.
	$(POD_ENV) $(GO) run cmd/controller/*.go init $(INIT_FLAGS)

# AGENT_AUTH_FLAGS ?= --kubernetes-auth=true --kubernetes-trusted-name=mariadb-galera --kubernetes-trusted-namespace=default
AGENT_AUTH_FLAGS ?=
AGENT_FLAGS ?= $(RUN_FLAGS) $(AGENT_AUTH_FLAGS) --config-dir=mariadb/config --state-dir=mariadb/state
.PHONY: agent
agent: local-dir ## Run agent from your host.
	$(POD_ENV) $(GO) run cmd/controller/*.go agent $(AGENT_FLAGS)

##@ Profile

PPROF_SAMPLE ?= heap
PPROF_FILE ?= pprof.out
PPROF_HTTP_ADDR ?= ":6061"

.PHONY: pprof-sample
pprof-sample: ## Get pprof sample.
	curl -s http://localhost$(PPROF_ADDR)/debug/pprof/$(PPROF_SAMPLE) > $(PPROF_FILE)

.PHONY: pprof
pprof: pprof-sample ## Start pprof HTTP server.
	$(GO) tool pprof -http=$(PPROF_HTTP_ADDR) $(PPROF_FILE)