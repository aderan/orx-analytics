## Stage 1: Preserve compatible baseline
**Goal**: Validate and commit existing ORX v12 support and remove generated files from Git.
**Success Criteria**: Existing tests pass; bytecode, egg-info and local runtime state are ignored.
**Tests**: Existing pytest suite, including v12 import and source ranking.
**Status**: Complete

## Stage 2: Installable standalone tool
**Goal**: Complete package metadata, one version source, module entry, artifact installation checks and CI.
**Success Criteria**: Wheel built from sdist installs in a clean environment; CLI works outside the checkout without runtime dependencies or real data access.
**Tests**: CLI module behavior; clean wheel/sdist install, version, help, registry and isolated collection.
**Status**: Complete

## Stage 3: Documentation
**Goal**: Record the independent-repository decision; document installation, upgrades, source support and contribution.
**Success Criteria**: Documentation matches verified commands and source capabilities.
**Tests**: Full pytest suite, package installation check and diff checks.
**Status**: Complete

## Stage 4: Safe remote delivery
**Goal**: Remove generated data from unpublished history after GitHub rejected a historical runtime database; preserve the original history locally and publish clean main.
**Success Criteria**: Local files and verified original-history backup remain available; generated data is absent from all published commits; GitHub main matches local HEAD; remote install and CI pass.
**Tests**: History path check, source and install regression, normal push with hooks/protection enabled, remote install and CI.
**Status**: In Progress
