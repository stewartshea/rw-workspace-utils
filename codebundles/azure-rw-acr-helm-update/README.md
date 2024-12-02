# RunWhen Local Helm Update Check (ACR)
This is intended for use by customers running a private ACR registry which RunWhen Local must use for it's images. It is intended to be paired with azure-rw-acr-sync. These two CodeBundles function as follows: 

- azure-rw-acr-sync (Not this CodeBundle) - Synchronizes upstream RunWhen images into Azure Container Registry on a regular basis when updates are available. 
- azure-rw-acr-helm-update (**This CodeBundle**) - Compares the running Helm release to the available images in ACR and applys a helm upgrade (cli based) if new images are available. 

CodeBundle Configuraiton: 
- REGISTRY_NAME - The ACR registry name
- REGISTRY_REPOSITORY_PATH - The root path/directory in the ACR registry to search for images
- HELM_APPLY_UPGRADE - Set to True to automatically apply the upgrade
- NAMESPACE - The Kubernetes namespace
- CONTEXT - The Kubernetes context
- HELM_RELEASE - The name of the helm release to inspect and update

This CodeBundle requires the following custom variables to be added to the workspaceInfo.yaml: 

```
custom: 
    private_registry: azure_acr
    azure_acr_registry: [ACR registry Name]
    azure_service_principal_secret_name: azure-sp (not required if spSecretName is set)
```

## SLI
The SLI runs the helm_update.sh script on a regular basis (defaulted to every 10m), listing the running images the helm release, looking for newer images in ACR, and generating the `helm upgrade` command needed to apply the update. If `HELM_APPLY_UPGRADE="true"`, the helm upgrade is automatically applied.

Pushes the metric of the total number of images that need to be updated. 


## Taskset
Performs the same function as the SLI, but adds the details to the report and can be run on demand. 