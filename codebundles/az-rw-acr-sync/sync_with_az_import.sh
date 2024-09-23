#!/bin/bash

# Set Private Registry
private_registry="${ACR_REGISTRY}"

# Set Architecture
desired_architecture="${IMAGE_ARCHITECTURE}"

# Specify values file
values_file="../sample_values.yaml"
new_values_file="../updated_values.yaml"

# Tag exclusion list
tag_exclusion_list=("tester")

# Generate a unique date-based tag
date_based_tag=$(date +%Y%m%d%H%M%S)

# Docker Hub credentials
docker_username="${DOCKER_USERNAME}"
docker_token="${DOCKER_TOKEN}"

# Ensure Docker credentials are set to avoid throttling
if [[ -z "$docker_username" || -z "$docker_token" ]]; then
    echo "Warning: Docker credentials (DOCKER_USERNAME and DOCKER_TOKEN) should be set to avoid throttling."
fi

runwhen_local_images=$(cat <<EOF
{
    "ghcr.io/runwhen-contrib/runwhen-local": {
        "destination": "runwhen/runwhen-local",
        "yaml_path": "runwhenLocal.image",
        "tag": "latest",
        "use_repository_only": false
    },
    "us-docker.pkg.dev/runwhen-nonprod-shared/public-images/runner": {
        "destination": "runwhen/runner",
        "yaml_path": "runner.image",
        "tag":"latest",
        "use_repository_only": false
    },
    "docker.io/otel/opentelemetry-collector": {
        "destination": "otel/opentelemetry-collector",
        "yaml_path": "opentelemetry-collector.image",
        "tag": "0.109.0",
        "use_repository_only": true
    },
    "docker.io/prom/pushgateway": {
        "destination": "prom/pushgateway",
        "yaml_path": "runner.pushgateway.image",
        "tag": "v1.9.0",
        "use_repository_only": false
    }
}
EOF
)

codecollection_images=$(cat <<EOF
{
    "us-west1-docker.pkg.dev/runwhen-nonprod-beta/public-images/runwhen-contrib-rw-cli-codecollection-main": {
        "destination": "runwhen/runwhen-contrib-rw-cli-codecollection-main",
        "yaml_path": "runner.runEnvironment.image"
    },
    "us-west1-docker.pkg.dev/runwhen-nonprod-beta/public-images/runwhen-contrib-rw-public-codecollection-main": {
        "destination": "runwhen/runwhen-contrib-rw-public-codecollection-main",
        "yaml_path": "runner.runEnvironment.image"
    },
    "us-west1-docker.pkg.dev/runwhen-nonprod-beta/public-images/runwhen-contrib-rw-generic-codecollection-main": {
        "destination": "runwhen/runwhen-contrib-rw-generic-codecollection-main",
        "yaml_path": "runner.runEnvironment.image"
    },
    "us-west1-docker.pkg.dev/runwhen-nonprod-beta/public-images/runwhen-contrib-rw-workspace-utils-main": {
        "destination": "runwhen/runwhen-contrib-rw-workspace-utils-main",
        "yaml_path": "runner.runEnvironment.image"
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


# Function to copy image using az acr import with Docker Hub authentication only if the source is Docker Hub
copy_image() {
    repository_image=$1
    src_tag=$2
    destination=$3
    dest_tag=$4

    echo "Importing image $repository_image:$src_tag to $private_registry/$destination:$dest_tag..."

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

# Function to update image registry and repository in values file
update_values_yaml_no_tag() {
    local registry=$1
    local repository=$2
    local yaml_path=$3

    yq eval ".${yaml_path}.registry = \"$registry\"" -i $new_values_file
    yq eval ".${yaml_path}.repository = \"$repository\"" -i $new_values_file
}

# Function to update image registry, repository, and tag in values file (registry and repository)
update_values_yaml() {
    local registry=$1
    local repository=$2
    local tag=$3
    local yaml_path=$4
    local use_repository_only=$5

    if [ "$use_repository_only" = true ]; then
        # Only use repository concatenated path
        yq eval ".${yaml_path}.repository = \"$registry/$repository\"" -i $new_values_file
    else
        # Use registry and repository separately
        yq eval ".${yaml_path}.registry = \"$registry\"" -i $new_values_file
        yq eval ".${yaml_path}.repository = \"$repository\"" -i $new_values_file
    fi
    yq eval ".${yaml_path}.tag = \"$tag\"" -i $new_values_file
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

# Main script
main() {

    # Create a backup of the original values file
    cp $values_file $new_values_file

    # Process CodeCollection images
    for repository_image in $(echo $codecollection_images | jq -r 'keys[]'); do
        # Extract the custom destination and yaml path
        custom_repo_destination=$(echo $codecollection_images | jq -r --arg repository_image "$repository_image" '.[$repository_image].destination')
        custom_destination_repo=$(echo $custom_repo_destination | awk -F '/' '{print $1}')
        yaml_path=$(echo $codecollection_images | jq -r --arg repository_image "$repository_image" '.[$repository_image].yaml_path')

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
        echo "Copying image: $repository_image:$selected_tag to $private_registry/$custom_repo_destination:$selected_tag"
        copy_image $repository_image $selected_tag $custom_repo_destination $selected_tag
        echo "Image $private_registry/$custom_repo_destination:$selected_tag pushed successfully"
        update_values_yaml $private_registry $custom_destination_repo $selected_tag $yaml_path
    done

    # Process RunWhen component images
    for repository_image in $(echo $runwhen_local_images | jq -r 'keys[]'); do
        # Extract the custom destination, yaml path, and use_repository_only flag
        custom_repo_destination=$(echo $runwhen_local_images | jq -r --arg repository_image "$repository_image" '.[$repository_image].destination')
        yaml_path=$(echo $runwhen_local_images | jq -r --arg repository_image "$repository_image" '.[$repository_image].yaml_path')
        use_repository_only=$(echo $runwhen_local_images | jq -r --arg repository_image "$repository_image" '.[$repository_image].use_repository_only')

        if has_tag "$repository_image" "$runwhen_local_images"; then
            tag=$(echo $runwhen_local_images | jq -r --arg repository_image "$repository_image" '.[$repository_image].tag')
            echo "Skipping fetching tags for $repository_image and using specified tag $tag"
            selected_tag=$tag
        else
            echo "----"
            echo "Processing RunWhen component image: $repository_image"
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
        if [ "$selected_tag" == "latest" ]; then
            selected_tag=$date_based_tag
            echo "Copying image: $repository_image:latest to $private_registry/$custom_repo_destination:$selected_tag"
            copy_image $repository_image latest $custom_repo_destination $selected_tag
        else
            echo "Copying image: $repository_image:$selected_tag to $private_registry/$custom_repo_destination:$selected_tag"
            copy_image $repository_image $selected_tag $custom_repo_destination $selected_tag
        fi
        update_values_yaml $private_registry $custom_repo_destination $selected_tag $yaml_path $use_repository_only
    done

    # Display updated new_values.yaml content if it exists
    if [ -f "$new_values_file" ]; then
        echo "Updated $new_values_file:"
        cat $new_values_file
    else
        echo "No $new_values_file file found."
    fi
}
# Execute the main script
main