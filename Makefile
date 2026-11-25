-include .env

MODEL_ROOT ?= $(CURDIR)/models
OVMS_PORT ?= 4444
QSR_UI_PORT ?= 8600
QSR_UI_HOST ?= 0.0.0.0
# Image source: REGISTRY=true (default) pulls the pre-built image; REGISTRY=false builds from source.
TAG ?= latest
REGISTRY ?= true
REGISTRY_URL ?= intel/
QSR_IMAGE ?= $(REGISTRY_URL)qsr-agent:$(TAG)
WEATHER_IMAGE ?= $(REGISTRY_URL)qsr-weather:$(TAG)
REGISTRY_LOWER := $(shell echo $(REGISTRY) | tr A-Z a-z)
HERMES_INSTALL_COMMIT ?=
HERMES_INSTALL_SHA256 ?=
HERMES_INSTALL_URL ?=
HOST_UID ?= $(shell id -u)
HOST_GID ?= $(shell id -g)
WEATHER_PORT ?= 8090
DEPLOYER_URL ?= http://deployer:8095/mcp
RENDER_DEVICE ?= $(firstword $(wildcard /dev/dri/renderD*))
RENDER_GID ?= $(shell if [ -n "$(RENDER_DEVICE)" ]; then stat -c '%g' "$(RENDER_DEVICE)"; else echo 992; fi)
TAG ?= latest

export MODEL_ROOT MODEL_ID OVMS_PORT QSR_UI_PORT QSR_UI_HOST
export HERMES_INSTALL_COMMIT HERMES_INSTALL_SHA256 HERMES_INSTALL_URL QSR_IMAGE WEATHER_IMAGE TAG
export HOST_UID HOST_GID RENDER_GID
export WEATHER_PORT
export TAG

.PHONY: init-env check build build-ready up up-ready down restart logs status download-models download-models-ready weather learn deployer connect-services

init-env:
	@cp .env.example .env
	@echo "Refreshed .env from .env.example"

download-models: init-env
	$(MAKE) --no-print-directory download-models-ready

download-models-ready:
	bash download_models/model_download.sh

check:
	@command -v docker >/dev/null || { echo "Docker is required" >&2; exit 1; }
	@docker info >/dev/null || { echo "Docker daemon is not available to this user" >&2; exit 1; }
	@test -n "$(RENDER_DEVICE)" -a -e "$(RENDER_DEVICE)" || { echo "No Intel render device found at /dev/dri/render*" >&2; exit 1; }
	@test -n "$(MODEL_ID)" || { echo "MODEL_ID is not set; set it in .env.example" >&2; exit 1; }
	@test -f "$(MODEL_ROOT)/$(MODEL_ID)/config.json" || { echo "Model missing: $(MODEL_ROOT)/$(MODEL_ID)/config.json. Download it first or set MODEL_ROOT/MODEL_ID." >&2; exit 1; }
	@case "$(QSR_MODEL_BASE_URL)" in *inference-router*) case ",$(COMPOSE_PROFILES)," in *,router,*) ;; *) echo "QSR_MODEL_BASE_URL points at inference-router but COMPOSE_PROFILES does not include 'router'; set both in .env.example" >&2; exit 1 ;; esac ;; esac
	@docker compose version >/dev/null

build: init-env
	$(MAKE) --no-print-directory build-ready

build-ready: check
	@if [ "$(REGISTRY_LOWER)" = "true" ]; then \
		echo "Pulling images $(QSR_IMAGE) and $(WEATHER_IMAGE) from registry..."; \
		docker compose pull qsr-agent weather; \
	else \
		echo "Building qsr-agent and weather images from source..."; \
		docker compose build qsr-agent weather; \
	fi

up: init-env
	$(MAKE) --no-print-directory up-ready

up-ready: check
	@if [ "$(REGISTRY_LOWER)" = "true" ]; then \
		echo "Pulling images $(QSR_IMAGE) and $(WEATHER_IMAGE) from registry..."; \
		docker compose pull qsr-agent weather; \
		docker compose up -d --no-build; \
	else \
		echo "Building qsr-agent and weather images from source..."; \
		docker compose build qsr-agent weather; \
		docker compose up -d; \
	fi
	@echo "QSR Operator UI: http://localhost:$(QSR_UI_PORT)"

down:
	docker compose --profile deployer down

restart:
	docker compose restart qsr-agent

# Deployer: lets the operator deploy the other QSR services from chat (see services/deployer/README.md).
# Creates its bearer token, builds and starts it, and registers it with the agent (kept across `make up`).
deployer:
	@test -f deployer-config/inventory.yaml || { echo "Missing deployer-config/inventory.yaml; copy deployer-config/inventory.example.yaml and edit it" >&2; exit 1; }
	@test -s deployer-config/known_hosts || { echo "Missing deployer-config/known_hosts; pin each node: ssh-keyscan -H <host> >> deployer-config/known_hosts" >&2; exit 1; }
	@ls deployer-config/keys/* >/dev/null 2>&1 || { echo "No SSH key in deployer-config/keys/" >&2; exit 1; }
	@test -s deployer-config/deployer.env || { umask 077; printf 'QSR_DEPLOYER_TOKEN=%s\n' "$$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')" > deployer-config/deployer.env; echo "Created deployer-config/deployer.env"; }
	@printf '%s\n' 'QSR_DEPLOYER_MCP_URL=$(DEPLOYER_URL)' '+COMPOSE_PROFILES=deployer' | bash scripts/set-env.sh .env.example
	$(MAKE) --no-print-directory init-env
	docker compose --profile deployer up -d --build deployer
	docker compose up -d --no-deps qsr-agent

# After the operator deployed services: write each deployed service's MCP URL (inventory `agent_env`)
# into .env.example and recreate the agent so it registers them.
connect-services:
	@test -s deployer-config/deployer.env || { echo "Run make deployer first" >&2; exit 1; }
	@lines=$$(docker compose --profile deployer run --rm --no-deps -T deployer agent-env) || exit 1; \
		printf '%s\n' "$$lines" | bash scripts/set-env.sh .env.example
	$(MAKE) --no-print-directory init-env
	docker compose up -d --no-deps qsr-agent

logs:
	docker compose logs -f --tail=100

status:
	docker compose ps

# Demo weather: make weather CONDITION=rain TEMP=12 (add NO_EVENT=1 to stage silently).
weather:
	@test -n "$(CONDITION)" || { echo "Usage: make weather CONDITION=clear|cloudy|fog|drizzle|rain|storm|snow [TEMP=12] [NO_EVENT=1]" >&2; exit 1; }
	docker compose exec weather weather-simulator set "$(CONDITION)" $(if $(TEMP),--temperature "$(TEMP)") $(if $(NO_EVENT),--no-event)

# Operator-taught learning: make learn ARGS="setup|import FILE|status|run|pending|approve ID|reject ID|finalize".
learn:
	docker compose exec qsr-agent python scripts/learn.py $(or $(ARGS),status)
