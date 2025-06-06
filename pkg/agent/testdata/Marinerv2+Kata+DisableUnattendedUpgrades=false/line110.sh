[Unit]
Description=AKS Secure TLS Bootstrap Client
ConditionPathExists=/usr/local/bin/aks-secure-tls-bootstrap-client
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes

ExecStart=/usr/local/bin/aks-secure-tls-bootstrap-client \
    --ensure-authorized \
    --next-proto=aks-tls-bootstrap \
    --cluster-ca-file=/etc/kubernetes/certs/ca.crt \
    --kubeconfig=/var/lib/kubelet/kubeconfig \
    --cred-file=/etc/kubernetes/certs/client.pem \
    --log-file=/var/log/azure/aks/secure-tls-bootstrap.log \
    --deadline=60s \
    $BOOTSTRAP_FLAGS

[Install]
WantedBy=multi-user.target
