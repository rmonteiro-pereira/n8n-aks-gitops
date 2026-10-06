{{/*
Sync policy shared by every child Application.

ServerSideApply: several of these charts ship CRDs larger than the 262144
bytes a client-side apply can store in the last-applied annotation.
*/}}
{{- define "apps.syncPolicy" -}}
automated:
  prune: true
  selfHeal: true
syncOptions:
  - CreateNamespace=true
  - ServerSideApply=true
retry:
  limit: 5
  backoff:
    duration: 30s
    factor: 2
    maxDuration: 10m
{{- end -}}

{{- define "apps.destination" -}}
server: https://kubernetes.default.svc
namespace: {{ . }}
{{- end -}}
