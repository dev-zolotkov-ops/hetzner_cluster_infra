# GitLab Runner Helm Chart

This chart deploys a GitLab Runner instance into your Kubernetes
cluster. For more information, please review [our documentation](https://docs.gitlab.com/charts/charts/gitlab/gitlab-runner).

## Cluster runners

Deploy or upgrade the three independent runner releases in the same namespace:

```sh
helm upgrade --install build-runner . --namespace gitlab-runner --create-namespace -f values.yaml
helm upgrade --install deploy-runner . --namespace gitlab-runner -f values.yaml -f deploy-values.yaml
helm upgrade --install test-runner . --namespace gitlab-runner -f values.yaml -f test-values.yaml
```

The deploy and test overrides use release-specific token Secret names so all
three releases can coexist without sharing registration credentials.

# Development

Please follow [development documentation](DEVELOPMENT.md).
