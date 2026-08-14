# Public ALB prerequisites (prod)

This folder prepares TLS before any public AWS Application Load Balancer is
created. The controller is already installed in `08_load_balancer_controller_prod`.

## 1. ACM certificate

Run:

```bash
./01_request_acm_certificate_prod.sh
./01_request_acm_certificate_prod.sh dns
```

Add every printed CNAME to the `nopega.net` Cloudflare DNS zone as **DNS only**
(grey cloud). Then wait for:

```bash
./01_request_acm_certificate_prod.sh verify
```

The status must be `ISSUED`. The certificate covers `trino.nopega.net` and
`airflow.nopega.net`; one ALB will use it for both hostnames.

## What comes next

Before applying an Ingress, Trino must use password authentication:

```bash
cd ../../../../set_up_component/02_trino_prod
./02_create_trino_auth_secrets_prod.sh
./03_install_trino_prod.sh
```

Only after the certificate is issued and Trino has completed its authenticated
rollout will the next setup create the ALB and ask you to point the two final
DNS names to its hostname.
