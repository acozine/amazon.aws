#!/usr/bin/env bash

set -o pipefail -eux

declare -a args
IFS='/:' read -ra args <<< "$1"

script="${args[0]}"

test="$1"

docker images ansible/ansible
docker images quay.io/ansible/*
docker ps

for container in $(docker ps --format '{{.Image}} {{.ID}}' | grep -v '^drydock/' | sed 's/^.* //'); do
    docker rm -f "${container}" || true  # ignore errors
done

docker ps

if [ -d /home/shippable/cache/ ]; then
    ls -la /home/shippable/cache/
fi

command -v python
python -V

command -v pip
pip --version
pip list --disable-pip-version-check

export PATH="${PWD}/bin:${PATH}"
export PYTHONIOENCODING='utf-8'

if [ "${JOB_TRIGGERED_BY_NAME:-}" == "nightly-trigger" ]; then
    COVERAGE=yes
    COMPLETE=yes
fi

if [ -n "${COVERAGE:-}" ]; then
    # on-demand coverage reporting triggered by setting the COVERAGE environment variable to a non-empty value
    export COVERAGE="--coverage"
elif [[ "${COMMIT_MESSAGE}" =~ ci_coverage ]]; then
    # on-demand coverage reporting triggered by having 'ci_coverage' in the latest commit message
    export COVERAGE="--coverage"
else
    # on-demand coverage reporting disabled (default behavior, always-on coverage reporting remains enabled)
    export COVERAGE="--coverage-check"
fi

if [ -n "${COMPLETE:-}" ]; then
    # disable change detection triggered by setting the COMPLETE environment variable to a non-empty value
    export CHANGED=""
elif [[ "${COMMIT_MESSAGE}" =~ ci_complete ]]; then
    # disable change detection triggered by having 'ci_complete' in the latest commit message
    export CHANGED=""
else
    # enable change detection (default behavior)
    export CHANGED="--changed"
fi

if [ "${IS_PULL_REQUEST:-}" == "true" ]; then
    # run unstable tests which are targeted by focused changes on PRs
    export UNSTABLE="--allow-unstable-changed"
else
    # do not run unstable tests outside PRs
    export UNSTABLE=""
fi

virtualenv --python /usr/bin/python3.7 ~/ansible-venv
set +ux
. ~/ansible-venv/bin/activate
set -ux

pip install setuptools==44.1.0

pip install https://github.com/ansible/ansible/archive/"${A_REV:-devel}".tar.gz --disable-pip-version-check

#ansible-galaxy collection install community.general
mkdir -p "${HOME}/.ansible/collections/ansible_collections/community"
mkdir -p "${HOME}/.ansible/collections/ansible_collections/google"
mkdir -p "${HOME}/.ansible/collections/ansible_collections/openstack"
cwd=$(pwd)
cd "${HOME}/.ansible/collections/ansible_collections/"
git clone https://github.com/ansible-collections/community.general community/general
git clone https://github.com/ansible-collections/community.aws community/aws
# community.general requires a lot of things we need to manual pull in
# once community.general is published this will be handled by galaxy cli
git clone https://github.com/ansible-collections/ansible_collections_google google/cloud
git clone https://opendev.org/openstack/ansible-collections-openstack openstack/cloud
ansible-galaxy collection install ansible.netcommon
cd "${cwd}"

export ANSIBLE_COLLECTIONS_PATHS="${HOME}/.ansible/"
SHIPPABLE_RESULT_DIR="$(pwd)/shippable"
TEST_DIR="${HOME}/.ansible/collections/ansible_collections/amazon/aws/"
mkdir -p "${TEST_DIR}"
cp -aT "${SHIPPABLE_BUILD_DIR}" "${TEST_DIR}"
cd "${TEST_DIR}"

function cleanup
{
    if [ -d tests/output/coverage/ ]; then
        if find tests/output/coverage/ -mindepth 1 -name '.*' -prune -o -print -quit | grep -q .; then
            # for complete on-demand coverage generate a report for all files with no coverage on the "other" job so we only have one copy
            if [ "${COVERAGE}" == "--coverage" ] && [ "${CHANGED}" == "" ] && [ "${test}" == "sanity/1" ]; then
                stub="--stub"
            else
                stub=""
            fi

            # shellcheck disable=SC2086
            ansible-test coverage xml --color --requirements --group-by command --group-by version ${stub:+"$stub"}
            cp -a tests/output/reports/coverage=*.xml "$SHIPPABLE_RESULT_DIR/codecoverage/"

            # analyze and capture code coverage aggregated by integration test target if not on 2.9, default if unspecified is devel
            if [ -z "${A_REV:-}" ] || [ "${A_REV:-}" != "stable-2.9" ]; then
                ansible-test coverage analyze targets generate -v "$SHIPPABLE_RESULT_DIR/testresults/coverage-analyze-targets.json"
            fi

            # upload coverage report to codecov.io only when using complete on-demand coverage
            if [ "${COVERAGE}" == "--coverage" ] && [ "${CHANGED}" == "" ]; then
                for file in tests/output/reports/coverage=*.xml; do
                    flags="${file##*/coverage=}"
                    flags="${flags%-powershell.xml}"
                    flags="${flags%.xml}"
                    # remove numbered component from stub files when converting to tags
                    flags="${flags//stub-[0-9]*/stub}"
                    flags="${flags//=/,}"
                    flags="${flags//[^a-zA-Z0-9_,]/_}"

                    bash <(curl -s https://ansible-ci-files.s3.us-east-1.amazonaws.com/codecov/codecov.sh) \
                        -f "${file}" \
                        -F "${flags}" \
                        -n "${test}" \
                        -t bc371da7-e5d2-4743-93b5-309f81d457a4 \
                        -X coveragepy \
                        -X gcov \
                        -X fix \
                        -X search \
                        -X xcode \
                    || echo "Failed to upload code coverage report to codecov.io: ${file}"
                done
            fi
        fi
    fi
    if [ -d  tests/output/junit/ ]; then
      cp -aT tests/output/junit/ "$SHIPPABLE_RESULT_DIR/testresults/"
    fi

    if [ -d tests/output/data/ ]; then
      cp -a tests/output/data/ "$SHIPPABLE_RESULT_DIR/testresults/"
    fi

    if [ -d  tests/output/bot/ ]; then
      cp -aT tests/output/bot/ "$SHIPPABLE_RESULT_DIR/testresults/"
    fi
}

trap cleanup EXIT

if [[ "${COVERAGE:-}" == "--coverage" ]]; then
    timeout=60
else
    timeout=45
fi

ansible-test env --dump --show --timeout "${timeout}" --color -v

"tests/utils/shippable/check_matrix.py"
"tests/utils/shippable/${script}.sh" "${test}"
