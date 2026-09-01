#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_dir"

section() {
	printf '\n[%s]\n' "$1"
}

mapfile -d '' -t shell_files < <(git ls-files -z -- '*.sh')
if [[ ${#shell_files[@]} -eq 0 ]]; then
	printf 'No tracked shell files found.\n' >&2
	exit 1
fi

section 'ShellCheck'
shellcheck "${shell_files[@]}"

section 'Bash syntax'
for shell_file in "${shell_files[@]}"; do
	bash -n "$shell_file"
done

section 'Debian maintenance smoke'
bash util/tests/debian-maintenance.sh

section 'util router smoke'
bash util/tests/util-router.sh

section 'cache-prune smoke'
bash util/tests/cache-prune.sh

section 'alias-chain smoke'
bash tests/aliases-smoke.sh

section 'root-utility smoke'
bash tests/root-utils-smoke.sh

section 'pkg-ioc smoke'
bash pkg-ioc/tests/smoke.sh

section 'build-system smoke'
(
	cd build_system
	./build.sh
)

section 'theme generation smoke'
(
	cd themegen
	bash gen.sh
)

printf '\nAll tracked shell gates passed.\n'
