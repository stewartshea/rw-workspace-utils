export REGISTRY_NAME="runwhensandboxacr.azurecr.io"
export REGISTRY_REPOSITORY_PATH="runwhen"
export WORKDIR=/robot_logs/azure-rw-acr-sync
export SYNC_IMAGES="true"
export REGISTRY_TYPE="acr"
export USE_DATE_TAG="true"

./test https://runwhen-contrib.github.io/helm-charts runwhen-contrib runwhen-local


export IMAGE_ARCHITECTURE="amd64"
export USE_DOCKER_AUTH="false"

# Notes
This test rig is hacky and needs clean up. It's using an existing cluster and resources not yet made by this folder. 