terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.24"
    }
  }
}

provider "azurerm" {
  features {}
}

# ====================================
# Variables
# ====================================

variable "resource_group_name" {
  description = "Name of the existing resource group"
  type        = string
  default     = "rg-gp-test"
}

variable "primary_location" {
  description = "Primary Azure region for main cluster"
  type        = string
  default     = "eastus2"
}

variable "secondary_location" {
  description = "Secondary Azure region for DR cluster"
  type        = string
  default     = "westus"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "container_image_version" {
  description = "Document Intelligence container image version"
  type        = string
  default     = "4.0.2024-11-30"
}

# ====================================
# Data Sources
# ====================================

data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

# ====================================
# Document Intelligence - Primary (eastus2)
# ====================================

resource "azurerm_cognitive_account" "di_primary" {
  name                = "cogn-di-main-${var.environment}"
  location            = var.primary_location
  resource_group_name = data.azurerm_resource_group.rg.name
  kind                = "FormRecognizer"
  sku_name            = "S0"

  tags = {
    environment = var.environment
    region      = "primary"
  }
}

# ====================================
# Document Intelligence - Secondary (westus)
# ====================================

resource "azurerm_cognitive_account" "di_secondary" {
  name                = "cogn-di-sec-${var.environment}"
  location            = var.secondary_location
  resource_group_name = data.azurerm_resource_group.rg.name
  kind                = "FormRecognizer"
  sku_name            = "S0"

  tags = {
    environment = var.environment
    region      = "secondary"
  }
}

# ====================================
# Cluster 1: Primary DI Container Cluster (Main - eastus2)
# ====================================

resource "azurerm_kubernetes_cluster" "di_primary" {
  name                = "aks-di-main-${var.environment}"
  location            = var.primary_location
  resource_group_name = data.azurerm_resource_group.rg.name
  dns_prefix          = "di-main-${var.environment}"
  kubernetes_version  = "1.32"

  default_node_pool {
    name            = "default"
    node_count      = 2
    vm_size         = "Standard_D4s_v3"
    os_disk_size_gb = 128

    tags = {
      cluster = "primary"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  # Configure Cilium as CNI
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    network_data_plane  = "cilium"
    service_cidr        = "10.0.0.0/16"
    dns_service_ip      = "10.0.0.10"
    pod_cidr            = "10.244.0.0/16"
  }

  tags = {
    environment = var.environment
    cluster     = "main"
  }
}

# ====================================
# Cluster 2: Secondary DI Container Cluster (DR - westus)
# ====================================

resource "azurerm_kubernetes_cluster" "di_secondary" {
  name                = "aks-di-sec-${var.environment}"
  location            = var.secondary_location
  resource_group_name = data.azurerm_resource_group.rg.name
  dns_prefix          = "di-sec-${var.environment}"
  kubernetes_version  = "1.32"

  default_node_pool {
    name            = "default"
    node_count      = 2
    vm_size         = "Standard_D4s_v3"
    os_disk_size_gb = 128

    tags = {
      cluster = "secondary"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  # Configure Cilium as CNI
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    network_data_plane  = "cilium"
    service_cidr        = "10.1.0.0/16"
    dns_service_ip      = "10.1.0.10"
    pod_cidr            = "10.245.0.0/16"
  }

  tags = {
    environment = var.environment
    cluster     = "secondary"
  }
}

# ====================================
# Kubernetes Providers
# ====================================

provider "kubernetes" {
  alias                  = "primary"
  host                   = azurerm_kubernetes_cluster.di_primary.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.di_primary.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.di_primary.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.di_primary.kube_config[0].cluster_ca_certificate)
}

provider "kubernetes" {
  alias                  = "secondary"
  host                   = azurerm_kubernetes_cluster.di_secondary.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.di_secondary.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.di_secondary.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.di_secondary.kube_config[0].cluster_ca_certificate)
}

# ====================================
# Helm Providers for Cilium & Hubble
# ====================================



# ====================================
# Namespace for DI Containers - Primary
# ====================================

resource "kubernetes_namespace" "di_primary" {
  provider = kubernetes.primary

  metadata {
    name = "document-intelligence"
    labels = {
      "app.kubernetes.io/name" = "document-intelligence"
    }
  }

  depends_on = [azurerm_kubernetes_cluster.di_primary]
}

# ====================================
# Namespace for DI Containers - Secondary
# ====================================

resource "kubernetes_namespace" "di_secondary" {
  provider = kubernetes.secondary

  metadata {
    name = "document-intelligence"
    labels = {
      "app.kubernetes.io/name" = "document-intelligence"
    }
  }

  depends_on = [azurerm_kubernetes_cluster.di_secondary]
}

# ====================================
# Secret for DI Billing Credentials - Primary
# ====================================

resource "kubernetes_secret" "di_credentials_primary" {
  provider = kubernetes.primary

  metadata {
    name      = "di-credentials"
    namespace = kubernetes_namespace.di_primary.metadata[0].name
  }

  type = "Opaque"

  data = {
    "api-key"  = azurerm_cognitive_account.di_primary.primary_access_key
    "endpoint" = azurerm_cognitive_account.di_primary.endpoint
  }

  depends_on = [
    kubernetes_namespace.di_primary,
    azurerm_cognitive_account.di_primary
  ]
}

# ====================================
# Secret for DI Billing Credentials - Secondary
# ====================================

resource "kubernetes_secret" "di_credentials_secondary" {
  provider = kubernetes.secondary

  metadata {
    name      = "di-credentials"
    namespace = kubernetes_namespace.di_secondary.metadata[0].name
  }

  type = "Opaque"

  data = {
    "api-key"  = azurerm_cognitive_account.di_secondary.primary_access_key
    "endpoint" = azurerm_cognitive_account.di_secondary.endpoint
  }

  depends_on = [
    kubernetes_namespace.di_secondary,
    azurerm_cognitive_account.di_secondary
  ]
}

# ====================================
# Network Policy - Primary (Restrict Traffic)
# ====================================

resource "kubernetes_network_policy" "di_primary" {
  provider = kubernetes.primary

  metadata {
    name      = "di-layout-network-policy"
    namespace = kubernetes_namespace.di_primary.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "di-layout"
      }
    }

    policy_types = ["Ingress", "Egress"]

    # Allow ingress only from specific sources
    ingress {
      from {
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name" = "ingress-nginx"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "5000"
      }
    }

    # Allow egress for DNS and external services
    egress {
      to {
        namespace_selector {}
      }
      ports {
        protocol = "UDP"
        port     = "53"
      }
    }

    # Allow egress to Azure services
    egress {
      to {
        pod_selector {}
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [kubernetes_namespace.di_primary]
}

# ====================================
# Network Policy - Secondary (Restrict Traffic)
# ====================================

resource "kubernetes_network_policy" "di_secondary" {
  provider = kubernetes.secondary

  metadata {
    name      = "di-layout-network-policy"
    namespace = kubernetes_namespace.di_secondary.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "di-layout"
      }
    }

    policy_types = ["Ingress", "Egress"]

    # Allow ingress only from specific sources
    ingress {
      from {
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name" = "ingress-nginx"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "5000"
      }
    }

    # Allow egress for DNS and external services
    egress {
      to {
        namespace_selector {}
      }
      ports {
        protocol = "UDP"
        port     = "53"
      }
    }

    # Allow egress to Azure services
    egress {
      to {
        pod_selector {}
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [kubernetes_namespace.di_secondary]
}

# ====================================
# Service Account - Primary
# ====================================

resource "kubernetes_service_account" "di_sa_primary" {
  provider = kubernetes.primary

  metadata {
    name      = "di-layout-sa"
    namespace = kubernetes_namespace.di_primary.metadata[0].name
  }

  depends_on = [kubernetes_namespace.di_primary]
}

# ====================================
# Service Account - Secondary
# ====================================

resource "kubernetes_service_account" "di_sa_secondary" {
  provider = kubernetes.secondary

  metadata {
    name      = "di-layout-sa"
    namespace = kubernetes_namespace.di_secondary.metadata[0].name
  }

  depends_on = [kubernetes_namespace.di_secondary]
}

# ====================================
# Document Intelligence Layout Deployment - Primary
# ====================================

resource "kubernetes_deployment" "di_layout_primary" {
  provider = kubernetes.primary

  metadata {
    name      = "di-layout-deployment"
    namespace = kubernetes_namespace.di_primary.metadata[0].name
    labels = {
      app     = "di-layout"
      version = "4.0"
    }
  }

  spec {
    replicas = 3

    selector {
      match_labels = {
        app = "di-layout"
      }
    }

    template {
      metadata {
        labels = {
          app = "di-layout"
        }
        annotations = {
          "container.apparmor.security.beta.kubernetes.io/di-layout" = "runtime/default"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.di_sa_primary.metadata[0].name

        container {
          name  = "di-layout"
          image = "mcr.microsoft.com/azure-cognitive-services/form-recognizer/layout-${var.container_image_version}"

          image_pull_policy = "IfNotPresent"

          # Resource requirements per Azure documentation
          resources {
            limits = {
              cpu    = "2"
              memory = "6Gi"
            }
            requests = {
              cpu    = "1.5"
              memory = "4Gi"
            }
          }

          env {
            name  = "EULA"
            value = "accept"
          }

          env {
            name = "Billing"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.di_credentials_primary.metadata[0].name
                key  = "endpoint"
              }
            }
          }

          env {
            name = "ApiKey"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.di_credentials_primary.metadata[0].name
                key  = "api-key"
              }
            }
          }

          port {
            name           = "http"
            container_port = 5000
            protocol       = "TCP"
          }

          liveness_probe {
            http_get {
              path   = "/ready"
              port   = 5000
              scheme = "HTTP"
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path   = "/ready"
              port   = 5000
              scheme = "HTTP"
            }
            initial_delay_seconds = 20
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          # Security context
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = false
            run_as_non_root           = true
            run_as_user               = 1000
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "tmp-volume"
            mount_path = "/tmp"
          }

          volume_mount {
            name       = "cache-volume"
            mount_path = "/home/user"
          }
        }

        # Pod-level security context
        security_context {
          fs_group             = 1000
          supplemental_groups  = [1000]
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        volume {
          name = "tmp-volume"
          empty_dir {}
        }

        volume {
          name = "cache-volume"
          empty_dir {}
        }

        affinity {
          # Pod anti-affinity to spread replicas across nodes
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                label_selector {
                  match_expressions {
                    key      = "app"
                    operator = "In"
                    values   = ["di-layout"]
                  }
                }
                topology_key = "kubernetes.io/hostname"
              }
            }
          }
        }
      }
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = 1
        max_unavailable = 0
      }
    }
  }

  depends_on = [
    kubernetes_namespace.di_primary,
    kubernetes_secret.di_credentials_primary
  ]
}

# ====================================
# Document Intelligence Layout Service - Primary
# ====================================

resource "kubernetes_service" "di_layout_primary" {
  provider = kubernetes.primary

  metadata {
    name      = "di-layout-service"
    namespace = kubernetes_namespace.di_primary.metadata[0].name
    labels = {
      app = "di-layout"
    }
  }

  spec {
    selector = {
      app = "di-layout"
    }

    port {
      name        = "http"
      port        = 5000
      target_port = 5000
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }

  depends_on = [kubernetes_deployment.di_layout_primary]
}

# ====================================
# Document Intelligence Layout Deployment - Secondary
# ====================================

resource "kubernetes_deployment" "di_layout_secondary" {
  provider = kubernetes.secondary

  metadata {
    name      = "di-layout-deployment"
    namespace = kubernetes_namespace.di_secondary.metadata[0].name
    labels = {
      app     = "di-layout"
      version = "4.0"
    }
  }

  spec {
    replicas = 3

    selector {
      match_labels = {
        app = "di-layout"
      }
    }

    template {
      metadata {
        labels = {
          app = "di-layout"
        }
        annotations = {
          "container.apparmor.security.beta.kubernetes.io/di-layout" = "runtime/default"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.di_sa_secondary.metadata[0].name

        container {
          name  = "di-layout"
          image = "mcr.microsoft.com/azure-cognitive-services/form-recognizer/layout-${var.container_image_version}"

          image_pull_policy = "IfNotPresent"

          # Resource requirements per Azure documentation
          resources {
            limits = {
              cpu    = "2"
              memory = "6Gi"
            }
            requests = {
              cpu    = "1.5"
              memory = "4Gi"
            }
          }

          env {
            name  = "EULA"
            value = "accept"
          }

          env {
            name = "Billing"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.di_credentials_secondary.metadata[0].name
                key  = "endpoint"
              }
            }
          }

          env {
            name = "ApiKey"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.di_credentials_secondary.metadata[0].name
                key  = "api-key"
              }
            }
          }

          port {
            name           = "http"
            container_port = 5000
            protocol       = "TCP"
          }

          liveness_probe {
            http_get {
              path   = "/ready"
              port   = 5000
              scheme = "HTTP"
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path   = "/ready"
              port   = 5000
              scheme = "HTTP"
            }
            initial_delay_seconds = 20
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          # Security context
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = false
            run_as_non_root           = true
            run_as_user               = 1000
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "tmp-volume"
            mount_path = "/tmp"
          }

          volume_mount {
            name       = "cache-volume"
            mount_path = "/home/user"
          }
        }

        # Pod-level security context
        security_context {
          fs_group             = 1000
          supplemental_groups  = [1000]
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        volume {
          name = "tmp-volume"
          empty_dir {}
        }

        volume {
          name = "cache-volume"
          empty_dir {}
        }

        affinity {
          # Pod anti-affinity to spread replicas across nodes
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                label_selector {
                  match_expressions {
                    key      = "app"
                    operator = "In"
                    values   = ["di-layout"]
                  }
                }
                topology_key = "kubernetes.io/hostname"
              }
            }
          }
        }
      }
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = 1
        max_unavailable = 0
      }
    }
  }

  depends_on = [
    kubernetes_namespace.di_secondary,
    kubernetes_secret.di_credentials_secondary
  ]
}

# ====================================
# Document Intelligence Layout Service - Secondary
# ====================================

resource "kubernetes_service" "di_layout_secondary" {
  provider = kubernetes.secondary

  metadata {
    name      = "di-layout-service"
    namespace = kubernetes_namespace.di_secondary.metadata[0].name
    labels = {
      app = "di-layout"
    }
  }

  spec {
    selector = {
      app = "di-layout"
    }

    port {
      name        = "http"
      port        = 5000
      target_port = 5000
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }

  depends_on = [kubernetes_deployment.di_layout_secondary]
}

# ====================================
# Outputs
# ====================================

output "primary_cluster_name" {
  description = "Primary AKS cluster name"
  value       = azurerm_kubernetes_cluster.di_primary.name
}

output "secondary_cluster_name" {
  description = "Secondary AKS cluster name"
  value       = azurerm_kubernetes_cluster.di_secondary.name
}

output "primary_cluster_id" {
  description = "Primary AKS cluster resource ID"
  value       = azurerm_kubernetes_cluster.di_primary.id
  sensitive   = true
}

output "secondary_cluster_id" {
  description = "Secondary AKS cluster resource ID"
  value       = azurerm_kubernetes_cluster.di_secondary.id
  sensitive   = true
}

output "note_service_access" {
  description = "Services are deployed with ClusterIP type. For external access, use kubectl port-forward or configure an Ingress controller with TLS."
  value       = "kubectl port-forward -n document-intelligence svc/di-layout-service 5000:5000"
}
