provider "kubernetes" {
  config_path = "${var.kubeconfig_filename}"
}

data "template_file" "registry-values" {
  template = <<EOF
storage: s3
s3:
  region: ${var.registry_config["s3_region"]}
  bucket: ${var.registry_config["s3_bucket"]}
  encrypt: true
  secure: true
persistence:
  deleteEnabled: true
configData:
  version: 0.1
  health:
    storagedriver:
      enabled: true
      interval: 10s
      threshold: 3
  http:
    addr: :5000
    headers:
      X-Content-Type-Options:
      - nosniff
  log:
    fields:
      service: registry
  storage:
    cache:
      blobdescriptor: inmemory
    delete:
      enabled: true
    maintenance:
      uploadpurging:
        enabled: true
        age: 168h
        interval: 24h
      readonly:
        enabled: false
  auth:
    token:
      realm: https://registry.ci.uktrade.io/console/v2/token
      service: registry.ci.uktrade.io
      issuer: registry.ci.uktrade.io
      rootcertbundle: /secrets/cert.pem
  notifications:
    endpoints:
      - name: portus
        url: https://registry.ci.uktrade.io/console/v2/webhooks/events
        timeout: 500ms
        threshold: 5
        backoff: 1s
EOF
}

resource "helm_release" "registry" {
  name = "docker-registry"
  namespace = "default"
  repository = "stable"
  chart = "docker-registry"
  version = "1.8.0"
  values = ["${data.template_file.registry-values.rendered}"]
}

resource "tls_private_key" "portus-tls-key" {
  algorithm = "RSA"
  rsa_bits = 2048
}

resource "tls_self_signed_cert" "portus-tls-cert" {
  key_algorithm = "${tls_private_key.portus-tls-key.algorithm}"
  private_key_pem = "${tls_private_key.portus-tls-key.private_key_pem}"
  subject {
    common_name = "registry.${var.cluster_domain}"
  }
  validity_period_hours = 87600
  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "data_encipherment",
    "server_auth",
    "client_auth",
    "any_extended"
  ]
}

resource "kubernetes_config_map" "portus-config" {
  metadata {
    name = "portus-config"
    namespace = "default"
  }
  data {
    PORTUS_DB_HOST = "${var.registry_config["db_host"]}"
    PORTUS_DB_DATABASE = "${var.registry_config["db_name"]}"
    PORTUS_DB_USERNAME = "${var.registry_config["db_user"]}"
    PORTUS_DB_PASSWORD = "${var.registry_config["db_password"]}"
    config.yml = <<EOF
machine_fqdn:
  value: registry.${var.cluster_domain}
check_ssl_usage:
  enabled: false
oauth:
  github:
    enabled: true
    client_id: "${var.registry_config["oauth_client_id"]}"
    client_secret: "${var.registry_config["oauth_client_secret"]}"
    organization: "${var.registry_config["oauth_organization"]}"
    team: "${var.registry_config["oauth_team"]}"
registry:
  jwt_expiration_time:
    value: 3600
  timeout:
    value: 2
  read_timeout:
    value: 180
  catalog_page:
    value: 100
delete:
  enabled: true
  contributors: true
  garbage_collector:
    enabled: true
    older_than: 180
    tag: ''
background:
  registry:
    enabled: true
  sync:
    enabled: true
    strategy: update-delete
security:
  clair:
    server: ''
    health_port: 6061
    timeout: 900
user_permission:
  change_visibility:
    enabled: true
  create_team:
    enabled: true
  manage_team:
    enabled: true
  create_namespace:
    enabled: true
  manage_namespace:
    enabled: true
  create_webhook:
    enabled: true
  manage_webhook:
    enabled: true
  push_images:
    policy: allow-teams
anonymous_browsing:
  enabled: true
first_user_admin:
  enabled: true
signup:
  enabled: false
display_name:
  enabled: true
gravatar:
  enabled: true
EOF
  }
}

data "template_file" "portus" {
  template = "${file("${path.module}/portus-dc.yaml")}"
}

resource "null_resource" "portus" {
  provisioner "local-exec" {
    command = <<EOF
cat <<EOL | kubectl -n default apply -f -
${data.template_file.portus.rendered}
EOL
EOF
    environment {
      KUBECONFIG = "${var.kubeconfig_filename}"
    }
  }
}

resource "kubernetes_service" "portus" {
  metadata {
    name = "portus"
    namespace = "default"
  }
  spec {
    selector {
      app = "portus"
    }
    type = "ClusterIP"
    port {
      name = "http"
      protocol = "TCP"
      port = 3000
      target_port = 3000
    }
  }
}
