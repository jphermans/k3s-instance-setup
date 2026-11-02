#!/usr/bin/env bash
#===============================================================================
#  k3s-instance-setup.sh
#-------------------------------------------------------------------------------
#  Purpose : Fully prepare a fresh Debian/Ubuntu instance with k3s, Helm 3 and
#            a selectable application stack: Agent Zero (A0), n8n, Grafana and
#            Cloudflared (Cloudflare Tunnel).
#  Version : 2.0.0
#  Author  : Agent Zero
#  License : MIT
#
#  Usage   :  sudo ./k3s-instance-setup.sh              (interactive, recommended)
#             sudo ./k3s-instance-setup.sh --dry-run    (preview only, no changes)
#             sudo ./k3s-instance-setup.sh -y            (accept all defaults)
#
#  Features:
#    - Interactive component menu: choose which containers to deploy.
#    - A resource proposal card for EVERY container (CPU request/limit, memory
#      request/limit, PVC storage, NodePort) that can be changed during the
#      run: ENTER = accept, e = edit, s = skip.
#    - Idempotent: re-running updates existing resources (kubectl apply,
#      helm upgrade --install). k3s and Helm are skipped when already present.
#    - Secrets are applied through Kubernetes Secrets (never plain YAML).
#
#  Environment variables (optional, useful with -y):
#    COMPONENTS          comma-separated: a0,n8n,grafana,cloudflared (or: all)
#    CLOUDFLARED_TOKEN   Cloudflare tunnel token (Cloudflared is skipped if unset)
#    A0_PASSWORD         Agent Zero login password
#    GRAFANA_PASSWORD    Grafana login password
#    N8N_ENCRYPTION_KEY  n8n encryption key
#===============================================================================

set -euo pipefail

#--[ Colors ]--------------------------------------------------------------------
readonly C_RESET=$'\e[0m'
readonly C_BOLD=$'\e[1m'
readonly C_DIM=$'\e[2m'
readonly C_RED=$'\e[1;31m'
readonly C_GREEN=$'\e[1;32m'
readonly C_YELLOW=$'\e[1;33m'
readonly C_BLUE=$'\e[1;34m'
readonly C_MAGENTA=$'\e[1;35m'
readonly C_CYAN=$'\e[1;36m'

#--[ Global state ]--------------------------------------------------------------
STEP=0
ASSUME_YES=0
DRY_RUN=0
K3S_INSTALLED=0
HELM_INSTALLED=0
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG
SUMMARY_FILE="/root/instance-setup-summary.txt"
CARD_W=56

declare -A RES   # RES[<key>:<field>]  keys: a0 | n8n | graf | cfd

#--[ UI helpers ]----------------------------------------------------------------
_box_line() {
  local s
  s=$(printf '%-*s' "$CARD_W" "${1:0:$CARD_W}")
  printf '  %s│ %s%s%s │%s\n' "$C_DIM" "$C_BOLD" "$s" "$C_DIM" "$C_RESET"
}

box() {
  local bar content
  printf -v bar '%*s' "$CARD_W" ''
  bar=${bar// /─}
  printf '  %s╭%s╮%s\n' "$C_DIM" "$bar" "$C_RESET"
  for content in "$@"; do _box_line "$content"; done
  printf '  %s╰%s╯%s\n' "$C_DIM" "$bar" "$C_RESET"
}

step() {
  STEP=$((STEP + 1))
  printf '\n%s🚀 STEP %02d — %s%s\n' "${C_BOLD}${C_CYAN}" "$STEP" "$*" "$C_RESET"
  printf '  %s────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
}

info() { printf '  %sℹ%s  %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '  %s✔%s  %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '  %s⚠%s  %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf '  %s✖ ERROR:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

#--[ Prompt helpers ]------------------------------------------------------------
ask() {   # ask <question> <default>  -> prints answer (or default)
  local q="$1" def="$2" a
  if [[ $ASSUME_YES -eq 1 ]]; then printf '%s\n' "$def"; return 0; fi
  read -r -p "$(printf '  %s>%s %s %s[%s]%s : ' "$C_CYAN" "$C_RESET" "$q" "$C_DIM" "$def" "$C_RESET")" a || true
  printf '%s\n' "${a:-$def}"
}

ask_choice() {   # ask_choice <question> <default> "opt1 opt2"
  local q="$1" def="$2" opts="$3" a
  while :; do
    a=$(ask "$q" "$def")
    if [[ ",$opts," == *",$a,"* ]]; then printf '%s\n' "$a"; return 0; fi
    warn "Pick one of: $opts"
    if [[ $ASSUME_YES -eq 1 ]]; then err "Invalid default value."; exit 1; fi
  done
}

ask_pw() {   # ask_pw <label>  -> prints password (auto-generated when left empty)
  local q="$1" a
  if [[ $ASSUME_YES -eq 1 ]]; then printf '%s\n' "$(gen_pw)"; return 0; fi
  read -r -p "$(printf '  %s>%s %s %s[auto-generate]%s : ' "$C_CYAN" "$C_RESET" "$q" "$C_DIM" "$C_RESET")" a || true
  printf '%s\n' "${a:-$(gen_pw)}"
}

ask_key() {   # ask_key <label>  -> prints hex key (auto-generated when left empty)
  local q="$1" a
  if [[ $ASSUME_YES -eq 1 ]]; then printf '%s\n' "$(openssl rand -hex 32)"; return 0; fi
  read -r -p "$(printf '  %s>%s %s %s[auto-generate]%s : ' "$C_CYAN" "$C_RESET" "$q" "$C_DIM" "$C_RESET")" a || true
  printf '%s\n' "${a:-$(openssl rand -hex 32)}"
}

#--[ Validators ]----------------------------------------------------------------
v_text() { [[ -n "$1" ]]; }
v_cpu()  {
  [[ "$1" =~ ^[0-9]+m$ ]] && return 0
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}
v_mem()  { [[ "$1" =~ ^[0-9]+(Ki|Mi|Gi|Ti)$ ]]; }
v_stor() { [[ "$1" == "-" ]] || v_mem "$1"; }
v_port() {
  [[ "$1" == "-" ]] && return 0
  if [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 30000 && "$1" <= 32767 )); then return 0; fi
  return 1
}

ask_valid() {   # ask_valid <question> <default> <validator-function>
  local q="$1" def="$2" vf="$3" v
  while :; do
    v=$(ask "$q" "$def")
    if "$vf" "$v"; then printf '%s\n' "$v"; return 0; fi
    warn "Invalid value '$v' — try again."
    if [[ $ASSUME_YES -eq 1 ]]; then err "Default value '$def' is invalid."; exit 1; fi
  done
}

gen_pw() { openssl rand -hex 12; }   # 24 hex chars, safe for YAML/Kubernetes

#--[ Resource proposal cards ]---------------------------------------------------
print_res_card() {
  local title="$1" image="$2" cpu_req="$3" cpu_lim="$4" mem_req="$5" mem_lim="$6" storage="$7" port="$8"
  local lines=()
  lines+=("▶ $title")
  lines+=("IMAGE     : $image")
  lines+=("CPU       : request $cpu_req   |   limit $cpu_lim")
  lines+=("MEMORY    : request $mem_req   |   limit $mem_lim")
  if [[ "$storage" != "-" ]]; then lines+=("STORAGE   : $storage PVC"); fi
  if [[ "$port" != "-" ]]; then lines+=("NODEPORT  : $port"); fi
  box "${lines[@]}"
}

collect_resources() {
  # $1 key $2 title $3 image $4 cpu_req $5 cpu_lim $6 mem_req $7 mem_lim $8 storage $9 nodeport
  local key="$1" title="$2" image="$3" cpu_req="$4" cpu_lim="$5" mem_req="$6" mem_lim="$7" storage="$8" port="${9:--}"
  local choice=""

  RES[${key}:enabled]=1
  print_res_card "$title" "$image" "$cpu_req" "$cpu_lim" "$mem_req" "$mem_lim" "$storage" "$port"

  if [[ $ASSUME_YES -ne 1 ]]; then
    read -r -p "$(printf '  %s  ENTER = accept   %se%s = edit   %ss%s = skip : %s' "$C_DIM" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_RESET")" choice || choice=""
    case "${choice:-}" in
      s|S)
        RES[${key}:enabled]=0
        warn "$title → skipped"
        ;;
      e|E)
        image=$(ask_valid   "image      (e.g. repo:tag)"            "$image"    v_text)
        cpu_req=$(ask_valid "CPU request (e.g. 500m or 0.5)"       "$cpu_req"  v_cpu)
        cpu_lim=$(ask_valid "CPU limit   (e.g. 2 or 1500m)"         "$cpu_lim"  v_cpu)
        mem_req=$(ask_valid "MEM request (e.g. 512Mi or 1Gi)"      "$mem_req"  v_mem)
        mem_lim=$(ask_valid "MEM limit   (e.g. 2Gi)"                "$mem_lim"  v_mem)
        storage=$(ask_valid "PVC storage (e.g. 10Gi, '-' = none)"   "$storage"  v_stor)
        port=$(ask_valid    "NodePort    (30000-32767, '-' = none)" "$port"     v_port)
        print_res_card "$title" "$image" "$cpu_req" "$cpu_lim" "$mem_req" "$mem_lim" "$storage" "$port"
        ;;
    esac
  fi

  RES[${key}:image]="$image"
  RES[${key}:cpu_req]="$cpu_req"
  RES[${key}:cpu_lim]="$cpu_lim"
  RES[${key}:mem_req]="$mem_req"
  RES[${key}:mem_lim]="$mem_lim"
  RES[${key}:storage]="$storage"
  RES[${key}:port]="$port"
}

#--[ Banner & component menu ]---------------------------------------------------
banner() {
  printf '\n'
  box "K3S INSTANCE SETUP — v2.0.0" "Interactive setup for a complete container stack"
  printf '   %sk3s%s · %sHelm%s · %sAgent Zero%s · %sn8n%s · %sGrafana%s · %sCloudflared%s\n' \
    "$C_CYAN" "$C_RESET" "$C_GREEN" "$C_RESET" "$C_MAGENTA" "$C_RESET" \
    "$C_YELLOW" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_RED" "$C_RESET"
  printf '\n'
}

select_components() {
  box "SELECT COMPONENTS TO DEPLOY" \
      "[1] Agent Zero (A0)  - autonomous AI agent" \
      "[2] n8n              - workflow automation" \
      "[3] Grafana          - dashboards & monitoring" \
      "[4] Cloudflared      - Cloudflare Tunnel"

  local default="all" answer token bad chosen
  local a0=0 n8n=0 graf=0 cfd=0
  [[ -n "${COMPONENTS:-}" ]] && default="$COMPONENTS"

  while :; do
    answer=$(ask "Components to deploy (numbers, 'all' or 'none')" "$default")
    a0=0; n8n=0; graf=0; cfd=0; bad=""
    if [[ "$answer" == "all" ]]; then
      a0=1; n8n=1; graf=1; cfd=1
    elif [[ "$answer" != "none" ]]; then
      IFS=', ' read -ra tokens <<<"$answer"
      for token in "${tokens[@]}"; do
        case "$token" in
          1|a0|agent-zero|agentzero) a0=1 ;;
          2|n8n)                     n8n=1 ;;
          3|grafana|graf)            graf=1 ;;
          4|cloudflared|cfd)         cfd=1 ;;
          "") : ;;
          *) bad="$token"; break ;;
        esac
      done
    fi
    if [[ -n "$bad" ]]; then
      warn "Unknown component '$bad' — use 1-4, 'all' or 'none'."
      if [[ $ASSUME_YES -eq 1 ]]; then err "Invalid COMPONENTS value."; exit 1; fi
      continue
    fi
    RES[a0:enabled]=$a0
    RES[n8n:enabled]=$n8n
    RES[graf:enabled]=$graf
    RES[cfd:enabled]=$cfd
    break
  done

  chosen=""
  if (( a0 ));   then chosen="${chosen} Agent Zero,"; fi
  if (( n8n ));  then chosen="${chosen} n8n,"; fi
  if (( graf )); then chosen="${chosen} Grafana,"; fi
  if (( cfd ));  then chosen="${chosen} Cloudflared,"; fi
  if [[ -n "$chosen" ]]; then
    ok "Selected:${chosen%,}"
  else
    warn "No components selected — only k3s + Helm will be installed."
  fi
}

#--[ Plan ]----------------------------------------------------------------------
plan_line() {
  local key="$1" label="$2"
  if [[ "${RES[${key}:enabled]}" != 1 ]]; then
    printf '  %s•%s %-11s: %sskipped%s\n' "$C_MAGENTA" "$C_RESET" "$label" "$C_DIM" "$C_RESET"
    return 0
  fi
  local extra=""
  if [[ "${RES[${key}:storage]}" != "-" ]]; then extra="$extra · PVC ${RES[${key}:storage]}"; fi
  if [[ "${RES[${key}:port]}" != "-" ]]; then extra="$extra · NodePort ${RES[${key}:port]}"; fi
  printf '  %s•%s %-11s: CPU %s/%s · MEM %s/%s%s\n' \
    "$C_MAGENTA" "$C_RESET" "$label" \
    "${RES[${key}:cpu_req]}" "${RES[${key}:cpu_lim]}" \
    "${RES[${key}:mem_req]}" "${RES[${key}:mem_lim]}" "$extra"
}

show_plan() {
  step "Execution plan"
  local k3s_action="fresh install (get.k3s.io)"
  local helm_action="fresh install (Helm v3)"
  if [[ $K3S_INSTALLED -eq 1 ]]; then k3s_action="already present → skip"; fi
  if [[ $HELM_INSTALLED -eq 1 ]]; then helm_action="already present → skip"; fi
  printf '  %s•%s %-11s: %s\n' "$C_MAGENTA" "$C_RESET" "K3S"       "$k3s_action"
  printf '  %s•%s %-11s: %s\n' "$C_MAGENTA" "$C_RESET" "HELM"      "$helm_action"
  printf '  %s•%s %-11s: %s\n' "$C_MAGENTA" "$C_RESET" "STORAGE"   "StorageClass ${STORAGE_CLASS}"
  printf '  %s•%s %-11s: %s\n' "$C_MAGENTA" "$C_RESET" "NODE-IP"   "$NODE_IP"
  plan_line a0   "AGENT ZERO"
  plan_line n8n  "N8N"
  plan_line graf "GRAFANA"
  plan_line cfd  "CLOUDFLARED"
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '\n'
    info "DRY RUN MODE — nothing will be changed."
  fi
}

confirm_plan() {
  if [[ $ASSUME_YES -eq 1 ]]; then return 0; fi
  printf '\n'
  warn "After confirmation, system-wide changes are applied (packages, k3s, deployments)."
  if [[ "$(ask_choice "Proceed with this plan? (y/n)" "y" "y n")" == "n" ]]; then
    warn "Aborted by user — nothing was changed."
    exit 0
  fi
}

#--[ Install & deploy helpers ]--------------------------------------------------
ns_apply() {
  kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  info "namespace '$1' present"
}

secret_apply() {   # secret_apply <ns> <name> <kubectl --from-literal args...>
  local ns="$1" name="$2"
  shift 2
  kubectl -n "$ns" create secret generic "$name" "$@" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  info "secret '$ns/$name' configured"
}

wait_rollout() {
  local ns="$1" name="$2"
  info "waiting for deployment $ns/$name ..."
  if kubectl -n "$ns" rollout status "deployment/$name" --timeout=420s; then
    ok "$ns/$name is ready"
  else
    warn "$ns/$name not ready within timeout — check: kubectl -n $ns get pods"
  fi
}

#--[ Preflight ]-----------------------------------------------------------------
preflight() {
  step "Preflight checks"
  if [[ $EUID -ne 0 ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      warn "Not running as root (allowed for --dry-run)."
    else
      err "Run this script as root (sudo)."
      exit 1
    fi
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    if [[ $DRY_RUN -eq 1 ]]; then
      warn "apt-get not found — a Debian/Ubuntu system is required for a real run."
    else
      err "Debian/Ubuntu required (apt-get not found)."
      exit 1
    fi
  fi
  if [[ $ASSUME_YES -eq 0 && $DRY_RUN -eq 0 && ! -t 0 ]]; then
    err "No interactive terminal. Use -y or run inside a TTY."
    exit 1
  fi
  if [[ $DRY_RUN -eq 0 ]]; then
    if ! curl -fsS --max-time 10 -o /dev/null https://get.k3s.io; then
      warn "get.k3s.io unreachable — check your internet connection."
    fi
  fi
  if command -v k3s >/dev/null 2>&1; then K3S_INSTALLED=1; info "k3s already installed → install step will be skipped."; fi
  if command -v helm >/dev/null 2>&1; then HELM_INSTALLED=1; info "helm already installed → install step will be skipped."; fi
  ok "Preflight OK."
}

#--[ Collect settings ]----------------------------------------------------------
collect_settings() {
  step "Settings & component selection"
  info "Tip: press ENTER to accept any [default] value."

  NODE_IP=$(ask "Node IP (ENTER = auto-detect)" "")
  if [[ -z "$NODE_IP" ]]; then
    NODE_IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+([.][0-9]+){3}$' | head -n 1) || true
    if [[ -z "${NODE_IP:-}" ]]; then NODE_IP="unknown"; fi
  fi
  STORAGE_CLASS=$(ask "StorageClass for PVCs (k3s default = local-path)" "local-path")

  select_components

  if [[ "${RES[a0:enabled]}" == 1 ]]; then
    A0_USER=$(ask "Agent Zero — login user" "admin")
    A0_PASSWORD=${A0_PASSWORD:-$(ask_pw "Agent Zero — login password")}
  fi
  if [[ "${RES[n8n:enabled]}" == 1 ]]; then
    N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY:-$(ask_key "n8n — encryption key")}
  fi
  if [[ "${RES[graf:enabled]}" == 1 ]]; then
    GRAFANA_USER=$(ask "Grafana — login user" "admin")
    GRAFANA_PASSWORD=${GRAFANA_PASSWORD:-$(ask_pw "Grafana — login password")}
  fi
  if [[ "${RES[cfd:enabled]}" == 1 ]]; then
    CLOUDFLARED_TOKEN=${CLOUDFLARED_TOKEN:-}
    if [[ -z "$CLOUDFLARED_TOKEN" ]]; then
      if [[ $ASSUME_YES -eq 1 ]]; then
        RES[cfd:enabled]=0
        warn "Cloudflared skipped (no CLOUDFLARED_TOKEN set)."
      else
        CLOUDFLARED_TOKEN=$(ask "Cloudflared — tunnel token (ENTER = skip Cloudflared)" "")
        if [[ -z "$CLOUDFLARED_TOKEN" ]]; then
          RES[cfd:enabled]=0
          warn "Cloudflared skipped (no token entered)."
        fi
      fi
    fi
  fi

  printf '\n'
  info "Resource proposals: ENTER = accept, e = edit, s = skip."
  if [[ "${RES[a0:enabled]}" == 1 ]]; then
    collect_resources a0   "AGENT ZERO (A0) — autonomous AI agent" "frdel/agent-zero-run:latest"      500m 2    1Gi   4Gi  50Gi 30080
  fi
  if [[ "${RES[n8n:enabled]}" == 1 ]]; then
    collect_resources n8n  "N8N — workflow automation"            "docker.n8n.io/n8nio/n8n:latest"   250m 1    512Mi 2Gi  10Gi 30567
  fi
  if [[ "${RES[graf:enabled]}" == 1 ]]; then
    collect_resources graf "GRAFANA — dashboards & monitoring"    "grafana/grafana (via Helm chart)" 100m 500m 256Mi 1Gi  10Gi 30300
  fi
  if [[ "${RES[cfd:enabled]}" == 1 ]]; then
    collect_resources cfd  "CLOUDFLARED — Cloudflare Tunnel"      "cloudflare/cloudflared:latest"    50m  250m 64Mi  256Mi -    -
  fi
}

#--[ Base system ]---------------------------------------------------------------
system_prep() {
  step "System preparation (apt)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates openssl
  ok "Base packages present (curl, ca-certificates, openssl)."
}

install_k3s() {
  if [[ $K3S_INSTALLED -eq 1 ]]; then
    info "k3s present: $(k3s --version | head -n 1)"
    return 0
  fi
  step "Installing k3s"
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -
  ok "k3s installed: $(k3s --version | head -n 1)"
}

wait_cluster() {
  step "Waiting for the cluster to become ready"
  if [[ ! -f "$KUBECONFIG" ]]; then err "kubeconfig $KUBECONFIG not found."; exit 1; fi
  local i=0
  until kubectl get nodes >/dev/null 2>&1; do
    i=$((i + 1))
    if [[ $i -gt 60 ]]; then err "kubectl not responding (120s)."; exit 1; fi
    sleep 2
  done
  kubectl wait --for=condition=Ready node --all --timeout=300s
  ok "All nodes Ready:"
  kubectl get nodes --no-headers | sed 's/^/    /'
}

install_helm() {
  if [[ $HELM_INSTALLED -eq 1 ]]; then
    info "helm present: $(helm version --short)"
    return 0
  fi
  step "Installing Helm v3"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  ok "helm installed: $(helm version --short)"
}

#--[ Component deploys ]---------------------------------------------------------
deploy_a0() {
  if [[ "${RES[a0:enabled]}" != 1 ]]; then info "Agent Zero skipped."; return 0; fi
  step "Deploying Agent Zero (A0)"
  local image="${RES[a0:image]}" cpu_req="${RES[a0:cpu_req]}" cpu_lim="${RES[a0:cpu_lim]}"
  local mem_req="${RES[a0:mem_req]}" mem_lim="${RES[a0:mem_lim]}" storage="${RES[a0:storage]}" port="${RES[a0:port]}"
  ns_apply agent-zero
  secret_apply agent-zero agent-zero-auth --from-literal="password=${A0_PASSWORD}"
  info "applying manifest (image: $image, NodePort: $port) ..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: agent-zero-data
  namespace: agent-zero
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: "${STORAGE_CLASS}"
  resources:
    requests:
      storage: "${storage}"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agent-zero
  namespace: agent-zero
  labels:
    app: agent-zero
    app.kubernetes.io/managed-by: k3s-instance-setup
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: agent-zero
  template:
    metadata:
      labels:
        app: agent-zero
    spec:
      containers:
        - name: agent-zero
          image: "${image}"
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 80
          env:
            - name: AUTH_LOGIN
              value: "${A0_USER}"
            - name: AUTH_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: agent-zero-auth
                  key: password
          resources:
            requests:
              cpu: "${cpu_req}"
              memory: "${mem_req}"
            limits:
              cpu: "${cpu_lim}"
              memory: "${mem_lim}"
          volumeMounts:
            - name: data
              mountPath: /a0
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: agent-zero-data
---
apiVersion: v1
kind: Service
metadata:
  name: agent-zero
  namespace: agent-zero
spec:
  type: NodePort
  selector:
    app: agent-zero
  ports:
    - name: http
      port: 80
      targetPort: http
      nodePort: ${port}
EOF
  wait_rollout agent-zero agent-zero
  ok "Agent Zero is running → http://${NODE_IP}:${port}"
}

deploy_n8n() {
  if [[ "${RES[n8n:enabled]}" != 1 ]]; then info "n8n skipped."; return 0; fi
  step "Deploying n8n"
  local image="${RES[n8n:image]}" cpu_req="${RES[n8n:cpu_req]}" cpu_lim="${RES[n8n:cpu_lim]}"
  local mem_req="${RES[n8n:mem_req]}" mem_lim="${RES[n8n:mem_lim]}" storage="${RES[n8n:storage]}" port="${RES[n8n:port]}"
  ns_apply n8n
  secret_apply n8n n8n-secrets --from-literal="encryption-key=${N8N_ENCRYPTION_KEY}"
  info "applying manifest (image: $image, NodePort: $port) ..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: n8n-data
  namespace: n8n
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: "${STORAGE_CLASS}"
  resources:
    requests:
      storage: "${storage}"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: n8n
  namespace: n8n
  labels:
    app: n8n
    app.kubernetes.io/managed-by: k3s-instance-setup
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: n8n
  template:
    metadata:
      labels:
        app: n8n
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      initContainers:
        - name: fix-perms
          image: busybox:1.36
          command: ["sh", "-c", "chown -R 1000:1000 /home/node/.n8n"]
          volumeMounts:
            - name: data
              mountPath: /home/node/.n8n
      containers:
        - name: n8n
          image: "${image}"
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 5678
          env:
            - name: N8N_ENCRYPTION_KEY
              valueFrom:
                secretKeyRef:
                  name: n8n-secrets
                  key: encryption-key
            - name: N8N_DIAGNOSTICS_ENABLED
              value: "false"
          resources:
            requests:
              cpu: "${cpu_req}"
              memory: "${mem_req}"
            limits:
              cpu: "${cpu_lim}"
              memory: "${mem_lim}"
          volumeMounts:
            - name: data
              mountPath: /home/node/.n8n
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: n8n-data
---
apiVersion: v1
kind: Service
metadata:
  name: n8n
  namespace: n8n
spec:
  type: NodePort
  selector:
    app: n8n
  ports:
    - name: http
      port: 80
      targetPort: http
      nodePort: ${port}
EOF
  wait_rollout n8n n8n
  ok "n8n is running → http://${NODE_IP}:${port}"
}

deploy_grafana() {
  if [[ "${RES[graf:enabled]}" != 1 ]]; then info "Grafana skipped."; return 0; fi
  step "Deploying Grafana (via Helm)"
  local cpu_req="${RES[graf:cpu_req]}" cpu_lim="${RES[graf:cpu_lim]}"
  local mem_req="${RES[graf:mem_req]}" mem_lim="${RES[graf:mem_lim]}" storage="${RES[graf:storage]}" port="${RES[graf:port]}"
  ns_apply monitoring
  secret_apply monitoring grafana-credentials \
    --from-literal="admin-user=${GRAFANA_USER}" \
    --from-literal="admin-password=${GRAFANA_PASSWORD}"
  info "adding/updating Helm repository 'grafana' ..."
  helm repo add grafana https://grafana.github.io/helm-charts --force-update >/dev/null
  helm repo update >/dev/null
  info "installing/upgrading Helm release 'grafana' (NodePort: $port) ..."
  helm upgrade --install grafana grafana/grafana \
    --namespace monitoring \
    --set admin.existingSecret=grafana-credentials \
    --set admin.userKey=admin-user \
    --set admin.passwordKey=admin-password \
    --set replicas=1 \
    --set persistence.enabled=true \
    --set "persistence.size=${storage}" \
    --set "persistence.storageClassName=${STORAGE_CLASS}" \
    --set service.type=NodePort \
    --set "service.nodePort=${port}" \
    --set "resources.requests.cpu=${cpu_req}" \
    --set "resources.requests.memory=${mem_req}" \
    --set "resources.limits.cpu=${cpu_lim}" \
    --set "resources.limits.memory=${mem_lim}" \
    --set "grafana.ini.server.root_url=http://${NODE_IP}:${port}/" >/dev/null
  wait_rollout monitoring grafana
  ok "Grafana is running → http://${NODE_IP}:${port}"
}

deploy_cfd() {
  if [[ "${RES[cfd:enabled]}" != 1 ]]; then info "Cloudflared skipped (no token)."; return 0; fi
  step "Deploying Cloudflared (Cloudflare Tunnel)"
  local image="${RES[cfd:image]}" cpu_req="${RES[cfd:cpu_req]}" cpu_lim="${RES[cfd:cpu_lim]}"
  local mem_req="${RES[cfd:mem_req]}" mem_lim="${RES[cfd:mem_lim]}"
  ns_apply cloudflared
  secret_apply cloudflared cloudflared-token --from-literal="tunnel-token=${CLOUDFLARED_TOKEN}"
  info "applying manifest (image: $image) ..."
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: cloudflared
  labels:
    app: cloudflared
    app.kubernetes.io/managed-by: k3s-instance-setup
spec:
  replicas: 2
  selector:
    matchLabels:
      app: cloudflared
  template:
    metadata:
      labels:
        app: cloudflared
    spec:
      containers:
        - name: cloudflared
          image: "${image}"
          args:
            - tunnel
            - --no-autoupdate
            - --metrics
            - 0.0.0.0:2000
            - run
          env:
            - name: TUNNEL_TOKEN
              valueFrom:
                secretKeyRef:
                  name: cloudflared-token
                  key: tunnel-token
          resources:
            requests:
              cpu: "${cpu_req}"
              memory: "${mem_req}"
            limits:
              cpu: "${cpu_lim}"
              memory: "${mem_lim}"
          livenessProbe:
            httpGet:
              path: /ready
              port: 2000
            initialDelaySeconds: 10
            periodSeconds: 20
EOF
  wait_rollout cloudflared cloudflared
  ok "Cloudflared connector(s) active — configure routing in the Cloudflare dashboard."
}

#--[ Reports ]-------------------------------------------------------------------
dry_run_report() {
  printf '\n'
  box "DRY RUN COMPLETE — NOTHING WAS CHANGED" \
      "Preview only: no packages, cluster or apps were touched." \
      "Re-run without --dry-run to execute this plan."
  printf '\n'
}

final_report() {
  step "Final check & summary"

  {
    echo "Instance setup summary — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Node IP     : ${NODE_IP}"
    echo "StorageClass: ${STORAGE_CLASS}"
    echo
    if [[ "${RES[a0:enabled]}" == 1 ]]; then
      echo "Agent Zero : http://${NODE_IP}:${RES[a0:port]}  (user: ${A0_USER}, password: ${A0_PASSWORD})"
      echo "  resources: CPU ${RES[a0:cpu_req]}/${RES[a0:cpu_lim]} · MEM ${RES[a0:mem_req]}/${RES[a0:mem_lim]} · PVC ${RES[a0:storage]}"
    fi
    if [[ "${RES[n8n:enabled]}" == 1 ]]; then
      echo "n8n        : http://${NODE_IP}:${RES[n8n:port]}"
      echo "  resources: CPU ${RES[n8n:cpu_req]}/${RES[n8n:cpu_lim]} · MEM ${RES[n8n:mem_req]}/${RES[n8n:mem_lim]} · PVC ${RES[n8n:storage]}"
    fi
    if [[ "${RES[graf:enabled]}" == 1 ]]; then
      echo "Grafana    : http://${NODE_IP}:${RES[graf:port]}  (user: ${GRAFANA_USER}, password: ${GRAFANA_PASSWORD})"
      echo "  resources: CPU ${RES[graf:cpu_req]}/${RES[graf:cpu_lim]} · MEM ${RES[graf:mem_req]}/${RES[graf:mem_lim]} · PVC ${RES[graf:storage]}"
    fi
    if [[ "${RES[cfd:enabled]}" == 1 ]]; then
      echo "Cloudflared: active (2 replicas, token-based tunnel)"
    fi
  } > "$SUMMARY_FILE"
  chmod 600 "$SUMMARY_FILE"

  printf '\n'
  box "SETUP COMPLETE" "All steps finished"
  if [[ "${RES[a0:enabled]}" == 1 ]]; then
    printf '  %s●%s Agent Zero : http://%s:%s  %s(%s / %s)%s\n' "$C_GREEN" "$C_RESET" "$NODE_IP" "${RES[a0:port]}" "$C_DIM" "$A0_USER" "$A0_PASSWORD" "$C_RESET"
  fi
  if [[ "${RES[n8n:enabled]}" == 1 ]]; then
    printf '  %s●%s n8n        : http://%s:%s\n' "$C_GREEN" "$C_RESET" "$NODE_IP" "${RES[n8n:port]}"
  fi
  if [[ "${RES[graf:enabled]}" == 1 ]]; then
    printf '  %s●%s Grafana    : http://%s:%s  %s(%s / %s)%s\n' "$C_GREEN" "$C_RESET" "$NODE_IP" "${RES[graf:port]}" "$C_DIM" "$GRAFANA_USER" "$GRAFANA_PASSWORD" "$C_RESET"
  fi
  if [[ "${RES[cfd:enabled]}" == 1 ]]; then
    printf "  %s●%s Cloudflared: %sactive (2 replicas)%s\n" "$C_GREEN" "$C_RESET" "$C_DIM" "$C_RESET"
  fi
  printf '\n'
  info "Credentials & resources also saved to: $SUMMARY_FILE (chmod 600)"
  info "Services overview:"
  kubectl get svc -A | grep -E 'NAMESPACE|agent-zero|n8n|grafana|cloudflared' | sed 's/^/    /' || true
  info "Pods overview:"
  kubectl get pods -A | grep -E 'NAMESPACE|agent-zero|n8n|grafana|cloudflared' | sed 's/^/    /' || true
  info "Tip: this script is idempotent — re-running updates existing resources."
  printf '\n'
  ok "Done! 🎉"
}

#--[ Usage & main ]--------------------------------------------------------------
usage() {
  cat <<'USAGE'
k3s-instance-setup.sh — interactive instance setup (v2.0.0)

Prepares a fresh Debian/Ubuntu instance with:
  • k3s (lightweight Kubernetes) + Helm 3
  • Agent Zero (A0)    — proposal: NodePort 30080, PVC 50Gi
  • n8n                — proposal: NodePort 30567, PVC 10Gi
  • Grafana (via Helm) — proposal: NodePort 30300, PVC 10Gi
  • Cloudflared tunnel — only when a token is provided

You choose which components to deploy, and every container gets a resource
proposal card (CPU request/limit, memory request/limit, PVC storage, NodePort)
that you can edit during the run.

Usage:
  sudo ./k3s-instance-setup.sh              interactive (recommended)
  sudo ./k3s-instance-setup.sh --dry-run    preview the flow, change nothing
  sudo ./k3s-instance-setup.sh -y           accept all defaults (non-interactive)

Options:
  -y, --yes      accept all defaults (non-interactive)
  -d, --dry-run  show the full interactive flow and plan, then exit (no changes)
  -h, --help     show this help

Environment variables (optional, useful with -y):
  COMPONENTS          comma-separated list: a0,n8n,grafana,cloudflared (or: all)
  CLOUDFLARED_TOKEN   Cloudflare tunnel token (Cloudflared is skipped if unset)
  A0_PASSWORD         Agent Zero login password
  GRAFANA_PASSWORD    Grafana login password
  N8N_ENCRYPTION_KEY  n8n encryption key
USAGE
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)     ASSUME_YES=1 ;;
      -d|--dry-run) DRY_RUN=1 ;;
      -h|--help)    usage; exit 0 ;;
      *) err "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
  done

  trap 'err "Script stopped by an error (line $LINENO)."' ERR

  banner
  preflight
  collect_settings
  show_plan
  if [[ $DRY_RUN -eq 1 ]]; then
    dry_run_report
    exit 0
  fi
  confirm_plan
  system_prep
  install_k3s
  wait_cluster
  install_helm
  deploy_a0
  deploy_n8n
  deploy_grafana
  deploy_cfd
  final_report
}

main "$@"
