.PHONY: up down restart logs status shell setup build

up:
	docker compose up -d

down:
	docker compose down

restart:
	docker compose down && docker compose up -d

logs:
	docker compose logs -f

status:
	docker compose ps

setup:
	cp -n .env.example .env || echo ".env already exists — edit it to add your API keys"
	docker compose up -d

build:
	docker compose build --no-cache
