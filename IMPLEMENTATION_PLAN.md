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

## Stage 3: Documentation and remote delivery
**Goal**: Record the independent-repository decision; document installation, upgrades, source support and contribution; push main.
**Success Criteria**: Documentation matches verified commands and source capabilities; GitHub main matches local HEAD.
**Tests**: Full pytest suite, package installation check, diff checks and remote commit comparison.
**Status**: In Progress
