# Orchestrator

Orchestrator is a repository for installing the base Crossplane compositions for IdPlatformKit. This repository sets up foundational infrastructure components and will also include additional reusable compositions in the future.

After the base compositions are installed, the instantiation and management of specific compositions will be handled in a separate repository.

## Purpose

- Provide a quick setup for base Crossplane compositions.
- Include a library of reusable Crossplane compositions for future use.
- Install and configure ArgoCD, which is used here only to install ArgoCD itself and to synchronize with the target repository containing the actual composition instances.

## Key Points

- **This repository does not manage application-specific compositions.**
- **ArgoCD in this context is only used for its installation and for syncing with the target repo.**
- **Future updates will add more reusable Crossplane compositions.**

## Getting Started

1. Clone this repository.
2. Install Crossplane and ArgoCD using the provided manifests.
3. Configure ArgoCD to sync with your target repository for composition instantiation.

## Next Steps

- Use your target repository to manage and instantiate specific Crossplane compositions.
- Check back for new reusable compositions as they are added to this repository.
