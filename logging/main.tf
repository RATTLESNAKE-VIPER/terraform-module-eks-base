resource "kubernetes_namespace" "logging" {
  metadata {
    name = "logging"
  }
}

data "template_file" "fluentd" {
  template = <<EOF
awsRegion: ${var.logging_config["aws_region"]}
awsAccessKeyId: ${var.logging_config["aws_access_key"]}
awsSecretAccessKey: ${var.logging_config["aws_secret_key"]}
logGroupName: "${var.cluster_name}-k8s"
rbac:
  create: true
extraVars:
  - "{name: CLUSTER_NAME, value: ${var.cluster_name}}"
EOF
}

resource "helm_release" "fluentd" {
  name = "fluentd-cloudwatch"
  namespace = "logging"
  repository = "incubator"
  chart = "fluentd-cloudwatch"
  version = var.helm_release["fluentd-cloudwatch"]
  values = ["${data.template_file.fluentd.rendered}", "${file("${path.module}/fluentd.conf")}"]
  depends_on = [kubernetes_namespace.logging]
}
