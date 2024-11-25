#!/bin/bash

# set -euo pipefail

# Base Variables
HELM_REPO_URL=$1   # Helm repository URL
HELM_REPO_NAME=$2  # Helm repository name
HELM_CHART_NAME=$3 # Helm chart name
export WORKDIR=${WORKDIR:-"./helm_work"}  # Output directory for all temporary files
OUTPUT_JSON="$WORKDIR/images_to_update.json"
RENDERED_YAML="$WORKDIR/rendered_chart.yaml"
REGISTRIES_TXT="$WORKDIR/registries.txt"
USE_DATE_TAG=${USE_DATE_TAG:-false} # Default is to not use date-based tags
export DATE_TAG=${DATE_TAG:-$(date +%Y%m%d%H%M%S)} # Default date tag if enabled
# Ensure Helm cache and repositories are correctly set

export HELM_CACHE_HOME="$TMPDIR/helm"
export HELM_CONFIG_HOME="/$TMPDIR/helm/config"
export HELM_DATA_HOME="$TMPDIR/helm/data"


# Registry-specific variables
export REGISTRY_TYPE=${REGISTRY_TYPE:-"acr"} # Default to ACR, can be "acr", "artifactory", "gcr", etc.
export REGISTRY_NAME=${REGISTRY_NAME:-""} # Generic registry name
export REGISTRY_URL="" # Registry URL/endpoint
export REGISTRY_REPOSITORY_PATH=${REGISTRY_REPOSITORY_PATH:-""} # Root path in registry
export SYNC_IMAGES=${SYNC_IMAGES:-false} # Whether to sync images

# Authentication variables
REGISTRY_USERNAME=""
REGISTRY_TOKEN=""
DOCKER_USERNAME=${DOCKER_USERNAME:-""} # Docker Hub username
DOCKER_TOKEN=${DOCKER_TOKEN:-""} # Docker Hub token

# Azure-specific variables
export AZURE_RESOURCE_SUBSCRIPTION_ID=${AZURE_RESOURCE_SUBSCRIPTION_ID:-""}

# Registry configuration
# Note: this has been written for ACR and has some scaffolding in place to 
# support other registries at a later date
case "$REGISTRY_TYPE" in
    "acr")
        if [[ -n "$REGISTRY_NAME" ]]; then
            REGISTRY_NAME="${REGISTRY_NAME%.azurecr.io}" # Remove .azurecr.io if it exists
            REGISTRY_URL="${REGISTRY_NAME}.azurecr.io"
            REGISTRY_REPOSITORY_PATH=${REGISTRY_REPOSITORY_PATH:-""}
            
            # Set Azure subscription
            if [ -z "$AZURE_RESOURCE_SUBSCRIPTION_ID" ]; then
                subscription=$(az account show --query "id" -o tsv)
                echo "Using current subscription ID: $subscription"
            else
                subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
                echo "Using specified subscription ID: $subscription"
            fi
            az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }
            TOKEN=$(az acr login -n "$REGISTRY_URL" --expose-token | jq -r .accessToken)
        else
            echo "Error: REGISTRY_NAME is not specified. Exiting."
            exit 1
        fi
        ;;
    "artifactory")
        REGISTRY_NAME=${ARTIFACTORY_NAME:-""}
        REGISTRY_URL=${ARTIFACTORY_URL:-""}
        REGISTRY_REPOSITORY_PATH=${ARTIFACTORY_ROOT_PATH:-""}
        REGISTRY_USERNAME=${ARTIFACTORY_USERNAME:-""}
        REGISTRY_TOKEN=${ARTIFACTORY_TOKEN:-""}
        # Add Artifactory-specific login logic here
        ;;
    "gcr")
        REGISTRY_NAME=${GCR_NAME:-""}
        REGISTRY_URL=${GCR_URL:-""}
        REGISTRY_REPOSITORY_PATH=${GCR_ROOT_PATH:-""}
        # Add GCR-specific login logic here
        ;;
    *)
        echo "Error: Unsupported registry type: $REGISTRY_TYPE"
        exit 1
        ;;
esac

# Registry-specific image import functions
function import_to_acr() {
    local source_image=$1
    local target_repo=$2
    local target_tag=$3
    
    local cmd="az acr import --name $REGISTRY_NAME --source $source_image --image $target_repo:$target_tag --force"
    if [[ "$source_image" == "docker.io"* && -n "$DOCKER_USERNAME" && -n "$DOCKER_TOKEN" ]]; then
        cmd+=" --username $DOCKER_USERNAME --password $DOCKER_TOKEN"
    fi
    
    eval "$cmd"
}

function import_to_artifactory() {
    local source_image=$1
    local target_repo=$2
    local target_tag=$3
    
    # Add Artifactory import logic here
    echo "Artifactory import not implemented yet"
}

function import_to_gcr() {
    local source_image=$1
    local target_repo=$2
    local target_tag=$3
    
    # Add GCR import logic here
    echo "GCR import not implemented yet"
}

function import_image() {
    local source_image=$1
    local target_repo=$2
    local target_tag=$3
    
    case "$REGISTRY_TYPE" in
        "acr")
            import_to_acr "$source_image" "$target_repo" "$target_tag"
            ;;
        "artifactory")
            import_to_artifactory "$source_image" "$target_repo" "$target_tag"
            ;;
        "gcr")
            import_to_gcr "$source_image" "$target_repo" "$target_tag"
            ;;
    esac
}

# Registry-specific tag check functions
function check_tag_exists_acr() {
    local repo=$1
    local tag=$2
    
    local tags=$(az acr repository show-tags --name "$REGISTRY_NAME" --repository "$repo" --output json 2>/dev/null || echo "[]")
    echo "$tags" | jq -e --arg tag "$tag" '.[] | select(. == $tag)' > /dev/null
}

function check_tag_exists_artifactory() {
    local repo=$1
    local tag=$2
    
    # Add Artifactory tag check logic here
    return 1
}

function check_tag_exists_gcr() {
    local repo=$1
    local tag=$2
    
    # Add GCR tag check logic here
    return 1
}

function check_tag_exists() {
    local repo=$1
    local tag=$2
    
    case "$REGISTRY_TYPE" in
        "acr")
            check_tag_exists_acr "$repo" "$tag"
            ;;
        "artifactory")
            check_tag_exists_artifactory "$repo" "$tag"
            ;;
        "gcr")
            check_tag_exists_gcr "$repo" "$tag"
            ;;
    esac
}

function setup_helm_repo() {
    local repo_url=$1
    local repo_name=$2

    echo "Adding Helm repository: $repo_name with URL: $repo_url..."
    helm repo add "$repo_name" "$repo_url" || true
    helm repo update
}

function get_latest_chart_version() {
    local repo_name=$1
    local chart_name=$2

    latest_version=$(helm search repo "$repo_name/$chart_name" --output json | jq -r '.[0].version')
    
    if [[ -z "$latest_version" ]]; then
        echo "Failed to fetch the latest version for $chart_name. Exiting." >&2
        exit 1
    fi

    echo "$latest_version"
}

function add_dependencies_repos() {
    local chart_dir=$1

    echo "Checking dependencies in $chart_dir/Chart.yaml..."
    if [[ ! -f "$chart_dir/Chart.yaml" ]]; then
        echo "Chart.yaml not found in $chart_dir. Skipping dependency resolution."
        return
    fi

    # Loop through dependencies and extract repository URLs
    yq eval '.dependencies[] | .repository' "$chart_dir/Chart.yaml" | while read -r repo; do
        if [[ -n "$repo" ]]; then
            # Check if the repository is already added
            if helm repo list | grep -q "$repo"; then
                echo "Repository with URL $repo is already added. Skipping..."
            else
                echo "Adding Helm repository with URL: $repo"
                helm repo add "$(basename "$repo")" "$repo" || true
            fi
        fi
    done

    # Update all Helm repositories
    echo "Updating Helm repositories for dependencies..."
    helm repo update
}



function pull_and_render_chart() {
    local repo_name=$1
    local chart_name=$2
    local chart_version=$3

    local chart_dir="$WORKDIR/$chart_name"

    if [[ -d "$chart_dir" ]]; then
        echo "Cleaning up existing directory: $chart_dir..."
        rm -rf "$chart_dir"
    fi

    echo "Pulling Helm chart: $chart_name (version: $chart_version) from $repo_name..."
    helm pull "$repo_name/$chart_name" --version "$chart_version" --untar --untardir "$WORKDIR"

    echo "Resolving dependencies for $chart_dir..."
    add_dependencies_repos "$chart_dir"

    echo "Removing tests subfolder if present..."
    if [[ -d "$chart_dir/templates/tests" ]]; then
        rm -rf "$chart_dir/templates/tests"
        echo "Removed $chart_dir/templates/tests."
    fi

    echo "Building Helm dependencies for $chart_name..."
    env > "$WORKDIR/debug_env.txt"
    echo "Current PATH: $PATH" >> "$WORKDIR/debug_env.log"
    helm repo list > "$WORKDIR/debug_helm.txt"
    ls -l "$WORKDIR" > "$WORKDIR/debug_ls.txt"

    pushd "$chart_dir" > /dev/null
    helm dependency build --debug # || { echo "Failed to build dependencies for $chart_name. Exiting."; exit 1; }
    popd > /dev/null

    echo "Rendering Helm chart to YAML..."
    pushd "$chart_dir" > /dev/null
    helm template . --set runner.enabled=true > "$RENDERED_YAML" || { echo "Failed to render Helm chart. Exiting."; exit 1; }
    popd > /dev/null

    if [[ ! -f "$RENDERED_YAML" ]]; then
        echo "Error: Rendered YAML file $RENDERED_YAML not found. Exiting."
        exit 1
    fi
}

function qualify_image_path() {
    local image="$1"

    if [[ "$image" == *:* ]]; then
        if [[ "$image" != */* ]]; then
            echo "docker.io/library/$image"
        elif [[ "$image" != *.*/* ]]; then
            echo "docker.io/$image"
        else
            echo "$image"
        fi
    else
        qualify_image_path "${image}:latest"
    fi
}

function extract_images() {
    echo "Extracting image configurations from rendered YAML..."

    > "$REGISTRIES_TXT"
    > "$WORKDIR/image_paths.txt"

    # Extract "image:" entries from the rendered YAML
    while IFS= read -r line; do
        # Match lines with `image:` and clean them
        if [[ "$line" =~ image: ]]; then
            # Trim spaces and quotes
            raw_image=$(echo "$line" | sed -E 's/.*image:[[:space:]]*"?([^"]+)"?/\1/')
            qualified_image=$(qualify_image_path "$raw_image")

            # Add to registries list
            echo "$qualified_image" >> "$REGISTRIES_TXT"
        fi
    done < "$RENDERED_YAML"

    # Ensure unique images
    sort -u "$REGISTRIES_TXT" -o "$REGISTRIES_TXT"

    echo "Extracted images:"
    cat "$REGISTRIES_TXT"
}



function get_image_metadata() {
    local image=$1
    local registry=$(echo "$image" | awk -F/ '{print $1}') # Extract registry name from the image

    case "$registry" in
        *.azurecr.io)
            metadata=$(skopeo inspect --creds "00000000-0000-0000-0000-000000000000:$TOKEN" docker://${image} 2>/dev/null || echo "{}")
            ;;
        docker.io)
            # Docker Hub (Public Registry)
            if [[ -n "$DOCKER_USERNAME" && -n "$DOCKER_TOKEN" ]]; then
                metadata=$(skopeo inspect --creds "$DOCKER_USERNAME:$DOCKER_TOKEN" docker://${image} 2>/dev/null || echo "{}")
            else
                metadata=$(skopeo inspect docker://${image} 2>/dev/null || echo "{}")
            fi
            ;;
        gcr.io | *.gcr.io)
            # Google Container Registry (GCR)
            if [[ -z "$GCR_TOKEN" ]]; then
                echo "Authenticating with GCR..."
                export GCR_TOKEN=$(gcloud auth print-access-token)
            fi
            metadata=$(skopeo inspect --creds "oauth2accesstoken:$GCR_TOKEN" docker://${image} 2>/dev/null || echo "{}")
            ;;
        *)
            # Unsupported or unauthenticated registry
            metadata=$(skopeo inspect docker://${image} 2>/dev/null || echo "{}")
            ;;
    esac

    # Validate JSON structure
    if ! echo "$metadata" | jq empty 2>/dev/null; then
        echo "Error: Invalid metadata retrieved for image: $image" >&2
        echo "{}"  # Return an empty JSON object
    else
        echo "$metadata"
    fi
}


function compare_image_dates() {
    local upstream_metadata=$1
    local private_metadata=$2

    upstream_date=$(echo "$upstream_metadata" | jq -r '.Created // empty')
    private_date=$(echo "$private_metadata" | jq -r '.Created // empty')

    if [[ -z "$upstream_date" ]]; then
        echo "Error: Unable to fetch creation date for upstream image."
        return 1
    fi
    if [[ -z "$private_date" ]]; then
        echo "Private image does not exist or lacks a creation date. Update required."
        return 0
    fi

    upstream_timestamp=$(date -d "$upstream_date" +%s || echo 0)
    private_timestamp=$(date -d "$private_date" +%s || echo 0)

    if (( upstream_timestamp > private_timestamp )); then
        echo "Upstream image is newer. Update required."
        return 0
    else
        echo "Private image is up-to-date."
        return 1
    fi
}

function list_private_tags() {
    local private_repo=$1

    tags=$(az acr repository show-tags --name "$REGISTRY_NAME" --repository "$private_repo" --orderby time_desc --output json 2>/dev/null || echo "[]")
    if ! echo "$tags" | jq empty; then
        echo "Error: Unable to list tags for repository: $private_repo" >&2
        echo "[]"
    else
        echo "$tags"
    fi
}

function get_recent_tag_metadata() {
    local private_repo=$1
    local recent_tags=$(list_private_tags "$private_repo" | jq -r '.[:5]') # Limit to 5 most recent tags

    for tag in $recent_tags; do
        local private_image="${REGISTRY_URL}/${private_repo}:${tag}"
        metadata=$(get_image_metadata "$private_image")
        # Validate metadata and return if it's valid
        if [[ -n "$(echo "$metadata" | jq -r '.Created // empty')" ]]; then
            echo "$metadata"
            return
        fi
    done

    echo "{}" # Return empty JSON if no valid metadata is found
}


function check_for_updates() {
    echo "Checking for updates to images..."
    echo "{}" > "$OUTPUT_JSON"

    while IFS= read -r upstream_image; do
        if [[ -z "$upstream_image" ]]; then
            continue
        fi

        qualified_upstream_image=$(qualify_image_path "$upstream_image")
        upstream_repo=$(echo "$qualified_upstream_image" | awk -F: '{print $1}')
        upstream_tag=$(echo "$qualified_upstream_image" | awk -F: '{print $2}')
        private_repo="${REGISTRY_REPOSITORY_PATH:+$REGISTRY_REPOSITORY_PATH/}$(basename "$upstream_repo")"

        echo "Fetching metadata for upstream image: $qualified_upstream_image"
        upstream_metadata=$(get_image_metadata "$qualified_upstream_image")

        if [[ -z "$(echo "$upstream_metadata" | jq -r '.Created // empty')" ]]; then
            echo "Error: Unable to fetch metadata for upstream image: $qualified_upstream_image"
            continue
        fi

        echo "Fetching metadata for recent private tags in: $private_repo"
        recent_tags=$(list_private_tags "$private_repo")
        tags=$(echo "$recent_tags" | sed -n '/^\[/,/\]$/p' | tr -d '[],"' | tr -s ' ' '\n')
        private_metadata="{}"

        for tag in $tags; do
            private_image="${REGISTRY_URL}/${private_repo}:${tag}"
            private_metadata=$(get_image_metadata "$private_image")

            if [[ -n "$(echo "$private_metadata" | jq -r '.Created // empty')" ]]; then
                break
            fi
        done

        if [[ "$(echo "$private_metadata" | jq -r '.Created // empty')" == "" ]]; then
            echo "No valid metadata found for private tags. Assuming update required."
            update_required="true"
            private_image="${REGISTRY_URL}/${private_repo}:${upstream_tag}"  # Default to upstream tag
        else
            echo "Comparing image creation dates..."
            if compare_image_dates "$upstream_metadata" "$private_metadata"; then
                update_required="true"
                private_image="${REGISTRY_URL}/${private_repo}:${upstream_tag}"  # Use upstream tag if update needed
            else
                update_required="false"
            fi
        fi

        jq --arg upstream_image "$qualified_upstream_image" \
           --arg private_image "$private_image" \
           --argjson update_required "$update_required" \
           '. + {($upstream_image): {private_image: $private_image, update_required: $update_required}}' \
           "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    done < "$REGISTRIES_TXT"

    echo "Updates written to $OUTPUT_JSON."
}


function sync_images_to_registry() {
    if [[ "$SYNC_IMAGES" != "true" ]]; then
        echo "SYNC_IMAGES is not enabled. Skipping sync."
        return
    fi

    echo "Importing images into registry..."

    jq -r 'to_entries[] | select(.value.update_required == true) | "\(.key)=\(.value.private_image)"' "$OUTPUT_JSON" | while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            continue
        fi

        upstream_image=$(echo "$line" | awk -F= '{print $1}')
        private_image_base=$(echo "$line" | awk -F= '{print $2}')

        upstream_repo=$(echo "$upstream_image" | awk -F: '{print $1}')
        upstream_tag=$(echo "$upstream_image" | awk -F: '{print $2}')

        target_repo="${REGISTRY_REPOSITORY_PATH:+$REGISTRY_REPOSITORY_PATH/}$(basename "$upstream_repo")"
        target_tag="$upstream_tag"

        if [[ "$target_tag" == "latest" && "$USE_DATE_TAG" == "true" ]]; then
            target_tag="$DATE_TAG"
            echo "Replacing 'latest' tag with date-based tag: $target_tag"
        fi

        private_image="${private_image_base}${target_tag}"

        echo "Importing $upstream_image into $private_image..."
        import_image "$upstream_image" "$target_repo" "$target_tag" || {
            echo "Failed to import $upstream_image. Skipping."
            continue
        }
        echo "Successfully imported $upstream_image into $private_image."

        # Update the JSON to reflect the new tag
        jq --arg upstream_image "$upstream_image" \
           --arg private_image "$private_image" \
           --argjson update_required false \
           '.[$upstream_image].private_image = $private_image | .[$upstream_image].update_required = $update_required' \
           "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    done

    echo "Image synchronization to registry completed."
}


# Main Execution
helm version >/dev/null 2>&1 || { echo "Helm not installed. Exiting."; exit 1; }
jq --version >/dev/null 2>&1 || { echo "jq not installed. Exiting."; exit 1; }
skopeo --version >/dev/null 2>&1 || { echo "Skopeo not installed. Exiting."; exit 1; }


# Create work directory
rm -rf "$WORKDIR" && mkdir -p "$WORKDIR"

setup_helm_repo "$HELM_REPO_URL" "$HELM_REPO_NAME"
latest_version=$(get_latest_chart_version "$HELM_REPO_NAME" "$HELM_CHART_NAME")
pull_and_render_chart "$HELM_REPO_NAME" "$HELM_CHART_NAME" "$latest_version"
extract_images
check_for_updates
sync_images_to_registry

