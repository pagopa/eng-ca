FROM hashicorp/vault:1.14@sha256:14be0a8eb323181a56d10facab3b424809d9921e85d2f2678126ce232766a8e1

COPY vault-server.hcl /etc/vault/config.hcl

CMD ["server", "-config", "/etc/vault/config.hcl"]
