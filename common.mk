#
# DO NOT EDIT
#

# Build flags for New Relic library
LDFLAGS = -ldflags "-r $(shell godep path)/src/github.com/shopkeep/go-rpm/newrelic/lib -extldflags -L$(shell godep path)/src/github.com/shopkeep/go-rpm/newrelic/lib"

# Branch used in the "update" target (defaults to "master")
BRANCH ?= master

# Clean the dependency name to match the docker-compose name
DependencyName = $(shell echo $1 | sed 's/-//')

# Check that a service dependency is running in Docker already
CheckServiceDependency = @docker ps | egrep '$(call DependencyName,$1)_$(call DependencyName,$2)' &> /dev/null || (echo 'No $1 running; go to the service and use "make run"'; exit 1)

.PHONY: help restore update build install clean vet lint install.vet install.lint install.godep test run artifact artifact.tag artifact.push deploy staging production check-env

#
# General targets
#

default: help

help: ## Show this help
	@fgrep -h "##" $(MAKEFILE_LIST) | fgrep -v fgrep | sed -Ee 's/([a-z.]*):[^#]*##(.*)/\1##\2/' | sort | column -t -s "##"

restore: ## Restore Godep dependencies
	$(info restoring dependencies)
	@godep restore

ifdef PACKAGE
update: restore ## Update a specific Godep dependency
	$(info checking out $(BRANCH))
	@git -C $(GOPATH)/src/$(PACKAGE) checkout -q $(BRANCH)
	$(info updating $(PACKAGE)/...)
	@godep update $(PACKAGE)/...
else
update:
	$(error You must specify a package to update (e.g. "make update PACKAGE=github.com/shopkeep/xyz"))
endif

build: install.godep ## Build the binary from source
	godep go build $(LDFLAGS) -o $(TARGET)

install: install.godep ## Install the binary
	godep go install $(LDFLAGS) ./...

clean: ## Clean the binary and tests
	-rm -f $(TARGET)
	$(info Removing test results)
	-rm -f test-results/*.xml

#
# Tools
#

vet: install.vet ## Run go vet
	go vet ./...

lint: install.lint ## Run golint
	golint ./...

install.vet: ## Install go vet
	@go get golang.org/x/tools/cmd/vet
	@go install golang.org/x/tools/cmd/vet

install.lint: ## Install golint
	@go get github.com/golang/lint/golint

install.cover: ## Install go cover
	@go get golang.org/x/tools/cmd/cover

install.godep: ## Install godep
	@go get github.com/tools/godep


#
# Build, test and deploy targets
#

CS_GIT_SHA = $(shell git rev-parse HEAD)

# CS_GIT_BRANCH is special cased because of the way Jenkins handles git
# repositories. When Jenkins checks out a commit the branch is left in a
# "detached head" state and thus it's not possible to determine the branch
# name using the same method we use locally.
ifndef GIT_BRANCH
	CS_GIT_BRANCH = $(shell git rev-parse --abbrev-ref HEAD)
else
	CS_GIT_BRANCH = $(shell echo $$GIT_BRANCH | cut -d / -f 2)
endif

# check if the git repository contains any untracked or changed files. If it
# does then we set a "dirty tag" that will be appended to any container tags
# or image names when built to indicate that the artifact was not built from
# a pristine git checkout.
IS_REPO_DIRTY = $(shell git diff --shortstat 2> /dev/null | tail -n1)
ifeq ($(strip $(IS_REPO_DIRTY)),)
	CS_DIRTY_TAG =
else
	CS_DIRTY_TAG= -dirty
endif

CS_DEPLOY_ENV =

staging: ## Sets up the environment for a staging build/deploy
	@echo Configuring staging build/deploy
	$(eval CS_DEPLOY_ENV = staging)
	$(eval CS_DOCKER_REGISTRY = $(CS_DOCKER_REGISTRY_STAGING))
	$(eval CS_MARATHON_JSON_API = $(CS_MARATHON_JSON_API_STAGING))

production: ## Sets up the environment for a production build/deploy
	@echo Configuring production build/deploy
	$(eval CS_DEPLOY_ENV = production)
	$(eval CS_DOCKER_REGISTRY = $(CS_DOCKER_REGISTRY_PRODUCTION))
	$(eval CS_MARATHON_JSON_API = $(CS_MARATHON_JSON_API_PRODUCTION))

check-env:
	@if [ "$(CS_DEPLOY_ENV)" == "" ]; then echo "Deploy environment not specified. You should call make staging <target> or make production <target>"; exit 1; fi

ifndef CONTAINERIZED
test: ## Run the unit tests in a Docker container against a Docker based database
	$(info running unit test containers)
	@docker-compose build test
	@docker-compose run test
else
test: vet lint install.cover install.godep ## (with "CONTAINERIZED=true") Run the unit tests directly via go
	godep go test $(LDFLAGS) -cover ./...
endif

run: ## Run the service in a Docker container
	$(info running service)
	@docker-compose build service
	@docker-compose up service

artifact: check-env artifact.push ## Build, tag and push a Docker image to the registry

artifact.tag: ## Build and tag a docker image for the current git revision
	docker build -t $(CS_DOCKER_REGISTRY)/$(CS_DOCKER_IMAGE_NAME):$(CS_GIT_BRANCH)-$(CS_GIT_SHA)$(CS_DIRTY_TAG) .

artifact.push: artifact.tag ## Push a docker image for the current git revision to the registry
	docker push $(CS_DOCKER_REGISTRY)/$(CS_DOCKER_IMAGE_NAME):$(CS_GIT_BRANCH)-$(CS_GIT_SHA)$(CS_DIRTY_TAG)

deploy: check-env ## Deploy built container to marathon
	@$(shell \
		CS_DOCKER_REGISTRY=$(CS_DOCKER_REGISTRY) \
		CS_MARATHON_APP_ID=$(CS_MARATHON_APP_ID) \
		CS_DEPLOY_ENV=$(CS_DEPLOY_ENV) \
		CS_DOCKER_IMAGE_NAME=$(CS_DOCKER_IMAGE_NAME) \
		CS_GIT_BRANCH=$(CS_GIT_BRANCH) \
		CS_GIT_SHA=$(CS_GIT_SHA) \
		CS_DIRTY_TAG=$(CS_DIRTY_TAG) \
		CS_DEPLOY_DOMAIN=platform.$(CS_DEPLOY_ENV).posrip.com \
		perl -pe 's;(\\*)(\$$([a-zA-Z_][a-zA-Z_0-9]*)|\$$\{([a-zA-Z_][a-zA-Z_0-9]*)\})?;substr($$1,0,int(length($$1)/2)).($$2&&length($$1)%2?$$2:$$ENV{$$3||$$4});eg' deploy.json.tmpl > deploy.json \
	)
	curl -f -k -XPUT -H "Content-Type: application/json" "$(CS_MARATHON_JSON_API)/v2/apps/$(CS_MARATHON_APP_ID)-$(CS_DEPLOY_ENV)" -d@"deploy.json"
