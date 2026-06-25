#!/bin/bash
# Move the control plane onto HAProxy once HAProxy is serving.
#
# kubeadm expects controlPlaneEndpoint to be the load-balancer address, but on
# a fresh install HAProxy is configured by the unlock manifest and started by
# Service Manager, so nothing listens on :6443 while "kubeadm init" runs.
# Bootstrap therefore uses the kube-apiserver port directly and this script
# moves the endpoint afterwards.
#
# kube-scheduler and kube-controller-manager are deliberately left on
# localAPIEndpoint: they are guaranteed to be co-located with kube-apiserver,
# so routing them through the load balancer adds a hop and a dependency for no
# availability gain.
#
# Idempotent in both directions. It is re-applied after a simplex-to-duplex
# migration, after an upgrade or rollback and after a restore, so it has to
# converge from whatever state it finds, including a system that was captured
# mid-migration.
set -u -o pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
PORT=6443
APISERVER_PORT=16443
BK=/etc/kubernetes/.pre-lb-endpoint
mkdir -p "$BK"

# Simplex runs a single kube-apiserver and no floating HAProxy instance, so
# there is nothing to load balance. Leaving the endpoint on the apiserver port
# is also what makes the simplex-to-duplex migration work: the converted system
# picks the endpoint up on its first unlock as a duplex.
MODE=$(awk -F= '/^system_mode=/{print $2}' /etc/platform/platform.conf 2>/dev/null)
if [ "$MODE" = "simplex" ]; then
    echo "simplex: control plane stays on the kube-apiserver port"
    exit 0
fi

VIP=$(getent hosts controller-cluster-host 2>/dev/null | awk '{print $1; exit}')
[ -n "${VIP:-}" ] || { echo "cannot resolve controller-cluster-host" >&2; exit 1; }

# Wrap the VIP in square brackets when it is IPv6 so it can be joined with a
# port. IPv4 needs no brackets. bash /dev/tcp takes the bare address, so the
# reachability check below still uses $VIP directly.
if [ "${VIP#*:}" != "$VIP" ]; then
    HOSTPORT="[${VIP}]:${PORT}"
else
    HOSTPORT="${VIP}:${PORT}"
fi
EP="https://${HOSTPORT}"

for i in $(seq 1 30); do
    timeout 3 bash -c "cat < /dev/null > /dev/tcp/${VIP}/${PORT}" 2>/dev/null && break
    sleep 2
done
timeout 3 bash -c "cat < /dev/null > /dev/tcp/${VIP}/${PORT}" 2>/dev/null || {
    echo "${HOSTPORT} not reachable; leaving the endpoint unchanged" >&2; exit 1; }

r=$(kubectl --server="$EP" get --raw /readyz 2>&1 | tr -d '\n')
[ "$r" = "ok" ] || { echo "${EP}/readyz returned '${r}'; leaving the endpoint unchanged" >&2; exit 1; }

# kubeadm regenerates kubeconfigs from the ConfigMap during joins, certificate
# renewal and upgrades, so the ConfigMap has to carry the load-balancer
# endpoint as well. A restore replays the etcd contents, which includes this
# ConfigMap, so the value is whatever the backup held: it is rewritten here
# rather than assumed.
CUR=$(kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null \
        | awk '/^controlPlaneEndpoint:/{print $2; exit}')
# The stored value is YAML-quoted (an IPv6 host:port must be quoted; see the
# sed below), so strip surrounding quotes before comparing to keep this a
# no-op on re-runs.
CUR=${CUR%\"}; CUR=${CUR#\"}
if [ "$CUR" != "${HOSTPORT}" ]; then
    # Fetch the current ClusterConfiguration into a variable first. Piping
    # kubectl straight into sed hides a kubectl failure: without pipefail the
    # pipeline reports sed's status, sed succeeds on empty input, and an empty
    # ClusterConfiguration would then be written over the live kubeadm-config.
    cc=$(kubectl -n kube-system get cm kubeadm-config \
        -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null)
    if [ -z "$cc" ]; then
        echo "could not read kubeadm-config; leaving it unchanged" >&2; exit 1
    fi

    # Keep a copy of the ConfigMap before changing it. If kubelet fails to come
    # up on the new endpoint, the rollback below restores this copy so the
    # ConfigMap and the kubeconfigs stay in agreement.
    [ -f "$BK/ClusterConfiguration" ] || printf '%s\n' "$cc" > "$BK/ClusterConfiguration"

    tmp=$(mktemp /tmp/kubeadm-cc.XXXXXX) || { echo "mktemp failed" >&2; exit 1; }
    # Quote the value: an IPv6 endpoint such as [aefd:205::1]:6443 is invalid
    # YAML when unquoted (the leading '[' starts a flow sequence), which makes
    # kubeadm fail to parse kubeadm-config. Quoting is harmless for IPv4.
    printf '%s\n' "$cc" \
        | sed "s|^controlPlaneEndpoint: .*|controlPlaneEndpoint: \"${HOSTPORT}\"|" > "$tmp"

    # Guard against writing an empty or truncated value back.
    if [ ! -s "$tmp" ] || ! grep -qF "controlPlaneEndpoint: \"${HOSTPORT}\"" "$tmp"; then
        rm -f "$tmp"; echo "refusing to write an invalid kubeadm-config" >&2; exit 1
    fi

    kubectl -n kube-system create cm kubeadm-config \
            --from-file=ClusterConfiguration="$tmp" --dry-run=client -o yaml \
        | kubectl replace -f - >/dev/null || {
            rm -f "$tmp"; echo "failed to update kubeadm-config" >&2; exit 1; }
    rm -f "$tmp"
    echo "kubeadm-config controlPlaneEndpoint set to ${HOSTPORT}"
fi

# admin.conf is captured by backup-system and replayed by a restore, so it can
# arrive holding either endpoint. Match on the port rather than assuming.
changed=0
for f in admin super-admin kubelet; do
    p=/etc/kubernetes/${f}.conf
    [ -f "$p" ] || continue
    case "$(awk '/server:/{print $2; exit}' "$p")" in
        *:${PORT}) continue ;;
    esac
    [ -f "$BK/${f}.conf" ] || cp -a "$p" "$BK/${f}.conf"
    sed -i "s|server: https://.*|server: ${EP}|" "$p"
    echo "${f}.conf now uses ${EP}"
    changed=1
done

[ "$changed" -eq 1 ] || exit 0

# pmon owns kubelet after the node is configured, so restart it via pmon like
# the rest of the puppet manifests do, not via systemctl.
/usr/local/sbin/pmon-restart kubelet
for i in $(seq 1 15); do
    sleep 4
    [ "$(systemctl is-active kubelet)" = "active" ] \
        && [ "$(kubectl get node "$(hostname)" --no-headers 2>/dev/null | awk '{print $2}')" = "Ready" ] \
        && { echo "kubelet is using ${EP}"; exit 0; }
done

# kubelet did not come up on the load balancer. Undo everything so the node
# keeps working on the kube-apiserver port, just without load balancing.
echo "kubelet did not become ready on ${EP}; restoring the previous endpoint" >&2

# Restore the ConfigMap so it matches the kubeconfigs we put back below.
if [ -f "$BK/ClusterConfiguration" ]; then
    kubectl -n kube-system create cm kubeadm-config \
            --from-file=ClusterConfiguration="$BK/ClusterConfiguration" \
            --dry-run=client -o yaml \
        | kubectl replace -f - >/dev/null \
        || echo "warning: could not restore kubeadm-config ConfigMap" >&2
fi

for f in admin super-admin kubelet; do
    [ -f "$BK/${f}.conf" ] && cp -a "$BK/${f}.conf" /etc/kubernetes/${f}.conf
done
/usr/local/sbin/pmon-restart kubelet
exit 1

