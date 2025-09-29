SHELL := /bin/bash

.PHONY: run docker build docker-run lint

run:
	perl bin/config-manager.pl daemon -l http://0.0.0.0:8080

docker:
	docker build -t config-manager:1.6.1 docker

docker-run:
	docker run --rm -p 8080:8080 -e API_TOKEN=changeme config-manager:1.6.1

lint:
	perl -c bin/config-manager.pl
