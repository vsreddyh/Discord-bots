.PHONY: up down restart logs status setup build

COMPOSE := docker compose --env-file ../.env -f docker-compose.yml

up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) down && $(COMPOSE) up -d

logs:
	$(COMPOSE) logs -f

status:
	$(COMPOSE) ps

setup:
	cp -n ../.env.example ../.env || echo ".env already exists — edit it to add your API keys"
	$(COMPOSE) up -d

build:
	$(COMPOSE) build --no-cache
