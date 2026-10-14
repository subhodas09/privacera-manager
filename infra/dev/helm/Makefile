SHELL := /bin/bash
.DEFAULT_GOAL := help
.NOTPARALLEL:

ARC_VERSION ?= 0.15.0
ARC_CONTROLLER_NAMESPACE ?= arc-systems
ARC_RUNNER_NAMESPACE ?= arc-runners
ARC_CONTROLLER_RELEASE ?= arc-controller
ARC_RUNNER_RELEASE ?= arc-runner-set
ARC_RUNNER_SCALE_SET_NAME ?= privacera-dev
ARC_CHART_ROOT := oci://ghcr.io/actions/actions-runner-controller-charts
ARC_DIR := actions-runner-controller
ARC_SECRET_FILE := $(ARC_DIR)/github_actions_secret.yml

.PHONY: help check-tools context namespaces arc-secret arc-controller arc-runners arc verify logs events watch-runners render

help:
	@echo "Repeatable Helm lifecycle for dev cluster add-ons"
	@echo ""
	@echo "  make context        Show the active Kubernetes context"
	@echo "  make render         Render both pinned ARC charts locally"
	@echo "  make arc            Apply namespaces, Secret, controller, and runner set"
	@echo "  make verify         Validate releases, registration, resources, and Secret metadata"
	@echo "  make logs           Show recent controller and listener logs"
	@echo "  make events         Show namespace events in chronological order"
	@echo "  make watch-runners  Watch ephemeral runner pods during a workflow"
	@echo ""
	@echo "ARC chart version: $(ARC_VERSION)"

check-tools:
	@command -v helm >/dev/null || { echo "helm is required" >&2; exit 1; }
	@command -v kubectl >/dev/null || { echo "kubectl is required" >&2; exit 1; }

context: check-tools
	@kubectl config current-context
	@kubectl cluster-info

namespaces: check-tools
	kubectl apply -f namespaces.yml

arc-secret: namespaces
	@test -f "$(ARC_SECRET_FILE)" || { \
		echo "Missing $(ARC_SECRET_FILE)" >&2; \
		echo "Copy the .example file, add the PAT locally, and retry." >&2; \
		exit 1; \
	}
	kubectl apply -f "$(ARC_SECRET_FILE)"

arc-controller: namespaces
	helm upgrade --install "$(ARC_CONTROLLER_RELEASE)" \
		"$(ARC_CHART_ROOT)/gha-runner-scale-set-controller" \
		--version "$(ARC_VERSION)" \
		--namespace "$(ARC_CONTROLLER_NAMESPACE)" \
		--values "$(ARC_DIR)/github_actions_controller_values.yml" \
		--atomic \
		--cleanup-on-fail \
		--history-max 5 \
		--wait \
		--wait-for-jobs \
		--timeout 10m

arc-runners: arc-secret arc-controller
	helm upgrade --install "$(ARC_RUNNER_RELEASE)" \
		"$(ARC_CHART_ROOT)/gha-runner-scale-set" \
		--version "$(ARC_VERSION)" \
		--namespace "$(ARC_RUNNER_NAMESPACE)" \
		--values "$(ARC_DIR)/github_actions_values.yml" \
		--atomic \
		--cleanup-on-fail \
		--history-max 5 \
		--wait \
		--wait-for-jobs \
		--timeout 10m

arc: arc-runners

verify: check-tools
	helm list --all-namespaces
	kubectl get pods -n "$(ARC_CONTROLLER_NAMESPACE)"
	kubectl get autoscalinglisteners -n "$(ARC_CONTROLLER_NAMESPACE)" -o wide
	kubectl get autoscalingrunnersets,ephemeralrunnersets,ephemeralrunners,pods -n "$(ARC_RUNNER_NAMESPACE)" -o wide
	kubectl describe autoscalingrunnerset "$(ARC_RUNNER_SCALE_SET_NAME)" -n "$(ARC_RUNNER_NAMESPACE)"
	kubectl describe secret arc-github-auth -n "$(ARC_RUNNER_NAMESPACE)"

logs: check-tools
	kubectl logs deployment/"$(ARC_CONTROLLER_RELEASE)-gha-rs-controller" \
		-n "$(ARC_CONTROLLER_NAMESPACE)" \
		--tail=120 \
		--prefix=true
	kubectl logs -n "$(ARC_CONTROLLER_NAMESPACE)" \
		-l actions.github.com/scale-set-name="$(ARC_RUNNER_SCALE_SET_NAME)" \
		--tail=120 \
		--prefix=true

events: check-tools
	kubectl get events -n "$(ARC_CONTROLLER_NAMESPACE)" --sort-by=.lastTimestamp
	kubectl get events -n "$(ARC_RUNNER_NAMESPACE)" --sort-by=.lastTimestamp

watch-runners: check-tools
	kubectl get pods,ephemeralrunners,ephemeralrunnersets \
		-n "$(ARC_RUNNER_NAMESPACE)" \
		--watch

render: check-tools
	@mkdir -p .rendered
	helm template "$(ARC_CONTROLLER_RELEASE)" \
		"$(ARC_CHART_ROOT)/gha-runner-scale-set-controller" \
		--version "$(ARC_VERSION)" \
		--namespace "$(ARC_CONTROLLER_NAMESPACE)" \
		--values "$(ARC_DIR)/github_actions_controller_values.yml" \
		> .rendered/arc-controller.yml
	helm template "$(ARC_RUNNER_RELEASE)" \
		"$(ARC_CHART_ROOT)/gha-runner-scale-set" \
		--version "$(ARC_VERSION)" \
		--namespace "$(ARC_RUNNER_NAMESPACE)" \
		--values "$(ARC_DIR)/github_actions_values.yml" \
		> .rendered/arc-runner-set.yml
	@echo "Rendered manifests are in .rendered/ (ignored by Git)."
