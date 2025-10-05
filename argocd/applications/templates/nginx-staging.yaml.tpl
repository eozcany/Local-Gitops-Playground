apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nginx-staging
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: root-apps
  source:
    repoURL: http://helm-repo.helm-repo.svc.cluster.local
    chart: nginx-app
    targetRevision: 0.1.0
    helm:
      releaseName: nginx-app
      valueFiles:
        - values-staging.yaml
      parameters:
        - name: image.repository
          value: nginx-demo
        - name: image.tag
          value: "1.0.0"
  destination:
    server: https://kubernetes.default.svc
    namespace: staging
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
