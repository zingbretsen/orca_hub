You can get dev logs for this orca hub instance via:
```
journalctl -u orca-hub | tail -n <Nlines>
```

## Kubernetes

To run kubectl commands, use the user's kubeconfig:
```
KUBECONFIG=~/.kube/k3s.yaml kubectl <command>
```

For example, to restart the deployment after pushing a new image:
```
KUBECONFIG=~/.kube/k3s.yaml kubectl rollout restart deployment/orca-hub -n lab
```
