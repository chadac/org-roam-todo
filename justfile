# org-roam-todo development commands
# Run with: just <command>

# Default recipe: run all tests
default: test

# Install dependencies via Cask (only if .cask is older than Cask file)
install:
    @if [ ! -d .cask ] || [ Cask -nt .cask ]; then \
        cask install && touch .cask; \
    fi

# All test files to load
_test_files := "-l test/org-roam-todo-test.el \
    -l test/org-roam-todo-core-test.el \
    -l test/org-roam-todo-wf-test-utils.el \
    -l test/org-roam-todo-wf-test.el \
    -l test/org-roam-todo-wf-validate-test.el \
    -l test/org-roam-todo-wf-actions-test.el \
    -l test/org-roam-todo-wf-actions-integration-test.el \
    -l test/org-roam-todo-wf-local-test.el \
    -l test/org-roam-todo-wf-pr-test.el \
    -l test/org-roam-todo-wf-tools-test.el"

# Internal: run tests with given selector, quiet on success
_test selector: install
    #!/usr/bin/env bash
    output=$(cask exec emacs -batch -L . -L test -l ert -l mocker \
        {{_test_files}} \
        --eval "(ert-run-tests-batch-and-exit {{selector}})" 2>&1)
    status=$?
    if [ $status -eq 0 ]; then
        echo "$output" | grep -E "^Ran [0-9]+ tests"
    else
        echo "$output"
        exit $status
    fi

# Run all tests (legacy + workflow) - quiet on success, verbose on failure
test:
    just _test "t"

# Run all tests with verbose output
test-verbose: install
    cask exec emacs -batch -L . -L test -l ert -l mocker \
        {{_test_files}} \
        -f ert-run-tests-batch-and-exit

# Run workflow tests only
test-wf:
    just _test "(quote (tag :wf))"

# Run only unit tests (fast, no external deps)
test-unit:
    just _test "(quote (tag :unit))"

# Run integration tests (requires git)
test-integration:
    just _test "(quote (tag :integration))"

# Run tests matching a pattern
test-match PATTERN:
    just _test "\"{{PATTERN}}\""

# Run legacy tests only (original org-roam-todo-test.el)
test-legacy: install
    cask exec emacs -batch -L . -L test \
        -l ert \
        -l test/org-roam-todo-test.el \
        -f ert-run-tests-batch-and-exit

# Byte-compile all elisp files
compile: install
    cask exec emacs -batch -L . \
        --eval "(setq byte-compile-error-on-warn t)" \
        -f batch-byte-compile *.el

# Clean compiled files and Cask artifacts
clean:
    rm -f *.elc test/*.elc
    rm -rf .cask

# Lint elisp files (requires package-lint)
lint: install
    cask exec emacs -batch -L . \
        --eval "(require 'package-lint)" \
        -f package-lint-batch-and-exit org-roam-todo.el org-roam-todo-list.el org-roam-todo-theme.el

# Check that all root .el files are required somewhere (prevents orphaned modules)
check-requires:
    #!/usr/bin/env bash
    set -e
    missing=()
    for f in org-roam-todo-*.el; do
        [[ "$f" == "org-roam-todo.el" ]] && continue  # skip main entry point
        feature=$(basename "$f" .el)
        if ! grep -rq "(require '$feature)" *.el; then
            missing+=("$feature")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: The following modules are not required anywhere:"
        printf '  - %s\n' "${missing[@]}"
        echo "Add them to org-roam-todo.el or another module."
        exit 1
    fi
    echo "All modules are properly required."

# Check for circular dependencies between elisp files
check-deps:
    #!/usr/bin/env bash
    set -e
    # Build dependency graph: for each file, find what it requires
    declare -A deps
    for f in org-roam-todo*.el; do
        feature=$(basename "$f" .el)
        # Extract requires (excluding external packages)
        requires=$(grep -oP "\\(require '\\Korg-roam-todo[^)]*" "$f" 2>/dev/null | tr '\n' ' ')
        deps[$feature]="$requires"
    done
    
    # DFS to detect cycles
    declare -A visiting visited
    cycles=()
    
    detect_cycle() {
        local node="$1"
        local path="$2"
        
        if [[ -n "${visiting[$node]}" ]]; then
            cycles+=("Circular dependency: $path -> $node")
            return 1
        fi
        [[ -n "${visited[$node]}" ]] && return 0
        
        visiting[$node]=1
        for dep in ${deps[$node]}; do
            detect_cycle "$dep" "$path -> $node" || true
        done
        unset visiting[$node]
        visited[$node]=1
    }
    
    for feature in "${!deps[@]}"; do
        detect_cycle "$feature" ""
    done
    
    if [[ ${#cycles[@]} -gt 0 ]]; then
        echo "ERROR: Circular dependencies detected:"
        printf '  %s\n' "${cycles[@]}"
        exit 1
    fi
    echo "No circular dependencies found."

# Show test tags available
test-tags:
    @echo "Available test tags:"
    @echo "  :unit        - Unit tests (no external deps)"
    @echo "  :integration - Integration tests (requires git)"
    @echo "  :wf          - Workflow engine tests"
    @echo "  :core        - Core workflow struct/transitions"
    @echo "  :validation  - Validation hook tests"
    @echo "  :tools       - MCP tool tests"
    @echo "  :github      - GitHub PR workflow tests"
    @echo "  :local       - Local fast-forward workflow tests"
    @echo "  :git         - Tests requiring git operations"
    @echo "  :mcp         - MCP-related tests"
    @echo "  :todo        - TODO management tests"
