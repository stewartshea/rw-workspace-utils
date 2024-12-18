#!/bin/bash

WORKDIR=${WORKDIR:-"./helm_work"}  # Output directory for all temporary files
OUTPUT_JSON="$WORKDIR/cc_images_to_update.json"
RENDERED_YAML="$WORKDIR/rendered_chart.yaml"
REGISTRIES_TXT="$WORKDIR/registries.txt"

# Registry-specific variables
REGISTRY_TYPE=${REGISTRY_TYPE:-"acr"} # Default to ACR, can be "acr", "artifactory", "gcr", etc.
REGISTRY_NAME=${REGISTRY_NAME:-""} # Generic registry name
REGISTRY_REPOSITORY_PATH=${REGISTRY_REPOSITORY_PATH:-""} # Root path in registry
SYNC_IMAGES=${SYNC_IMAGES:-false} # Whether to sync images

# Clean Output File
rm -f $OUTPUT_JSON

# Set Private Registry
private_registry="${REGISTRY_NAME}"

# Set Architecture
desired_architecture="${IMAGE_ARCHITECTURE:-"amd64"}"


# Tag exclusion list
tag_exclusion_list=("tester")


# Docker Hub credentials
docker_username="${DOCKER_USERNAME}"
docker_token="${DOCKER_TOKEN}"

# Check if AZURE_RESOURCE_SUBSCRIPTION_ID is set, otherwise get the current subscription ID
if [ -z "$AZURE_RESOURCE_SUBSCRIPTION_ID" ]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }

# Ensure Docker credentials are set to avoid throttling
if [[ -z "$docker_username" || -z "$docker_token" ]]; then
    echo "Warning: Docker credentials (DOCKER_USERNAME and DOCKER_TOKEN) should be set to avoid throttling."
fi

az acr login -n "$private_registry"
codecollection_images=$(cat <<EOF
{
    "us-west1-docker.pkg.dev/runwhen-nonprod-beta/public-images/runwhen-contrib-rw-cli-codecollection-main": {
        "destination": "$REGISTRY_REPOSITORY_PATH/runwhen-contrib-rw-cli-codecollection-main"
    },
    "us-west1-docker.pkg.dev/runwhen-nonprod-beta/public-images/runwhen-contrib-rw-public-codecollection-main": {
        "destination": "$REGISTRY_REPOSITORY_PATH/runwhen-contrib-rw-public-codecollection-main"
    },
    "us-west1-docker.pkg.dev/runwhen-nonprod-beta/public-images/runwhen-contrib-rw-generic-codecollection-main": {
        "destination": "$REGISTRY_REPOSITORY_PATH/runwhen-contrib-rw-generic-codecollection-main"
    },
    "us-west1-docker.pkg.dev/runwhen-nonprod-beta/public-images/runwhen-contrib-rw-workspace-utils-main": {
        "destination": "$REGISTRY_REPOSITORY_PATH/runwhen-contrib-rw-workspace-utils-main"
    }
}
EOF
)

# Ensure all required tools are installed
if ! command -v curl &> /dev/null; then
    echo "curl could not be found, please install it."
    exit
fi

if ! command -v yq &> /dev/null; then
    echo "yq could not be found, please install it."
    exit
fi

if ! command -v jq &> /dev/null; then
    echo "jq could not be found, please install it."
    exit
fi

# Function to get tags sorted by creation date from a repository image
get_sorted_tags_by_date() {
    repository_image=$1
    echo "Fetching tags for repository image: $repository_image with architecture: $desired_architecture" >&2

    # Check if the repository image is from Google Artifact Registry or Docker
    if [[ $repository_image == *.pkg.dev/* ]]; then
        REPO_URL="https://us-west1-docker.pkg.dev/v2/${repository_image#*pkg.dev/}/tags/list"
        TAGS=$(curl -s "$REPO_URL" | jq -r '.tags[]')
    elif [[ $repository_image == docker.io/* ]]; then
        REPO_URL="https://registry.hub.docker.com/v2/repositories/${repository_image#docker.io/}/tags"
        TAGS=$(eval curl -s "$REPO_URL" | jq -r '.results[].name')
    else
        echo "Unsupported repository type: $repository_image" >&2
        return
    fi

    if [ -z "$TAGS" ]; then
        echo "No tags found for $repository_image" >&2
        return
    fi

    tag_dates=()
    for TAG in $TAGS; do
        echo "Processing tag: $TAG" >&2
        if is_excluded_tag "$TAG" || [[ $TAG == "latest" ]]; then
            echo "Skipping $TAG" >&2
            continue
        fi

        if [[ $repository_image == *.pkg.dev/* ]]; then
            MANIFEST=$(curl -s "https://us-west1-docker.pkg.dev/v2/${repository_image#*pkg.dev/}/manifests/$TAG")
            # Check if the manifest is multi-arch
            media_type=$(echo "$MANIFEST" | jq -r '.mediaType')
            if [ "$media_type" == "application/vnd.docker.distribution.manifest.list.v2+json" ]; then
                # Multi-arch manifest
                MANIFESTS=$(echo "$MANIFEST" | jq -c --arg arch "$desired_architecture" '.manifests[] | select(.platform.architecture == $arch)')

                for MANIFEST_ITEM in $MANIFESTS; do
                    ARCH_MANIFEST_DIGEST=$(echo "$MANIFEST_ITEM" | jq -r '.digest')
                    ARCH_MANIFEST=$(curl -s "https://us-west1-docker.pkg.dev/v2/${repository_image#*pkg.dev/}/manifests/$ARCH_MANIFEST_DIGEST")
                    CONFIG_DIGEST=$(echo "$ARCH_MANIFEST" | jq -r '.config.digest')
                    CONFIG=$(curl -L -s "https://us-west1-docker.pkg.dev/v2/${repository_image#*pkg.dev/}/blobs/$CONFIG_DIGEST")
                    CREATION_DATE=$(echo "$CONFIG" | jq -r '.created')
                    if [ -n "$CREATION_DATE" ]; then
                        tag_dates+=("$CREATION_DATE $TAG")
                        break
                    fi
                done
            else
                # Single-arch manifest
                CONFIG_DIGEST=$(echo "$MANIFEST" | jq -r '.config.digest')
                CONFIG=$(curl -L -s "https://us-west1-docker.pkg.dev/v2/${repository_image#*pkg.dev/}/blobs/$CONFIG_DIGEST")
                CREATION_DATE=$(echo "$CONFIG" | jq -r '.created')
                
                if [ -n "$CREATION_DATE" ]; then
                    tag_dates+=("$CREATION_DATE $TAG")
                fi
            fi
        elif [[ $repository_image == docker.io/* ]]; then
            echo "Processing Docker Hub tag: $TAG"
            # Docker Hub logic can be expanded if needed for multi-arch
        else
            echo "Unsupported repository type: $repository_image" >&2
            return
        fi
    done

    if [ ${#tag_dates[@]} -eq 0 ]; then
        return
    fi

    # Sort tags by creation date
    sorted_tags=$(printf "%s\n" "${tag_dates[@]}" | sort -r | awk '{print $2}')
    echo $sorted_tags
}

# Function to check if a tag exists in the destination registry
# Function to check if a tag exists in the destination registry
tag_exists_in_acr() {
    local destination_image=$1
    local destination_tag=$2
    echo "Checking if tag $destination_tag exists in $private_registry/$destination_image..."

    # First, check if the repository exists
    az acr repository show -n "$private_registry" --repository "$destination_image" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "Repository $destination_image does not exist in $private_registry. Flagging as needing update."
        return 1  # Needs update
    fi

    # Then check if the tag exists
    az acr manifest list-metadata "$private_registry/$destination_image" \
        --query "[?tags[?@=='$destination_tag']]" | jq -e '. | length > 0' > /dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo "Tag $destination_tag exists in $private_registry/$destination_image."
        return 0  # Tag exists
    else
        echo "Tag $destination_tag does not exist in $private_registry/$destination_image."
        return 1  # Needs update
    fi
}



# Modify the copy_image function
copy_image() {
    repository_image=$1
    src_tag=$2
    destination=$3
    dest_tag=$4

    # Check if the destination tag already exists
    echo "Checking $destination for tag $dest_tag" >&2
    if tag_exists_in_acr "$destination" "$dest_tag"; then
        echo "Destination tag $dest_tag already exists in $private_registry/$destination. Skipping import."  >&2
        return
    fi

    echo "Importing image $repository_image:$src_tag to $private_registry/$destination:$dest_tag..." >&2

    # Initialize the command with the basic az acr import structure
    cmd="az acr import -n ${private_registry} --source ${repository_image}:${src_tag} --image ${destination}:${dest_tag} --force"

    # Conditionally add Docker authentication if the repository is from Docker Hub and credentials are set
    if [[ $repository_image == docker.io/* ]]; then
        if [[ -n "$docker_username" && -n "$docker_token" ]]; then
            echo "Docker Hub image detected. Using Docker credentials for import..."
            cmd+=" --username ${docker_username} --password ${docker_token}"
        else
            echo "Warning: Docker Hub image detected but credentials are not set. Throttling might occur."
        fi
    else
        echo "Non-Docker Hub image detected. No Docker credentials needed."
    fi

    # Execute the dynamically constructed command
    eval $cmd

    # Check if the import succeeded
    if [ $? -ne 0 ]; then
        echo "Error: Failed to import image ${repository_image}:${src_tag} to ${private_registry}/${destination}:${dest_tag}"
        exit 1
    fi

    echo "Image ${private_registry}/${destination}:${dest_tag} imported successfully"
}




# Check if a tag is in the exclusion list
is_excluded_tag() {
    local tag=$1
    for excluded_tag in "${tag_exclusion_list[@]}"; do
        if [ "$tag" == "$excluded_tag" ]; then
            return 0
        fi
    done
    return 1
}

# Check if the repository image has a tag already specified
has_tag() {
    local repository_image=$1
    local images_json=$2
    jq -e --arg repository_image "$repository_image" '.[($repository_image)].tag != null' <<< "$images_json" > /dev/null 2>&1
}

#Main
main() {
    for repository_image in $(echo $codecollection_images | jq -r 'keys[]'); do
        custom_repo_destination=$(echo $codecollection_images | jq -r --arg repository_image "$repository_image" '.[$repository_image].destination')
        custom_destination_repo=$(echo $custom_repo_destination | awk -F '/' '{print $1}')

        if has_tag "$repository_image" "$codecollection_images"; then
            tag=$(echo $codecollection_images | jq -r --arg repository_image "$repository_image" '.[$repository_image].tag')
            echo "Skipping fetching tags for $repository_image and using specified tag $tag"
            selected_tag=$tag
        else
            echo "----"
            echo "Processing CodeCollection image: $repository_image"
            sorted_tags=$(get_sorted_tags_by_date $repository_image)
            selected_tag=""
            for tag in $sorted_tags; do
                if is_excluded_tag $tag; then
                    echo "Skipping excluded tag: $tag"
                    continue
                fi
                selected_tag=$tag
                break
            done
        fi

        # Check if the repository or tag exists
        if ! tag_exists_in_acr "$custom_repo_destination" "$selected_tag"; then
            echo "Flagging $custom_repo_destination:$selected_tag as needing an update."

            # Always append to JSON-formatted output
            echo "{\"source\": \"$repository_image:$selected_tag\", \"destination\": \"$private_registry/$custom_repo_destination:$selected_tag\"}," >> $OUTPUT_JSON

            if [[ "$SYNC_IMAGES" == "true" ]]; then
                copy_image $repository_image $selected_tag $custom_repo_destination $selected_tag
                echo "Image $private_registry/$custom_repo_destination:$selected_tag pushed successfully"
            fi
        else
            echo "Skipping: $custom_repo_destination:$selected_tag already exists."
        fi
    done
}



# Execute the main script
main

# Finalize JSON output (if SYNC_IMAGES is false, finalize only once at the end)
if [[ "$SYNC_IMAGES" != "true" && -f $OUTPUT_JSON ]]; then
    sed -i '$ s/,$//' $OUTPUT_JSON  # Remove trailing comma from the last entry
    {
        echo "["
        cat $OUTPUT_JSON
        echo "]"
    } > "${OUTPUT_JSON}.tmp" && mv "${OUTPUT_JSON}.tmp" $OUTPUT_JSON
    echo "Image update list written to $OUTPUT_JSON"
fi