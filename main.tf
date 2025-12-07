terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# Variables
variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "di-container-dr-rg"
}

variable "primary_location" {
  description = "Primary Azure region"
  type        = string
  default     = "eastus2"
}

variable "secondary_location" {
  description = "Secondary Azure region"
  type        = string
  default     = "westus"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "document_intelligence_key" {
  description = "Document Intelligence API Key"
  type        = string
  sensitive   = true
}

variable "document_intelligence_endpoint" {
  description = "Document Intelligence Endpoint URI"
  type        = string
  sensitive   = true
}

# Resource Group - Primary
resource "azurerm_resource_group" "rg_primary" {
  name     = "${var.resource_group_name}-primary"
  location = var.primary_location

  tags = {
    environment = var.environment
    solution    = "document-intelligence-dr"
    region      = "primary"
  }
}

# Resource Group - Secondary
resource "azurerm_resource_group" "rg_secondary" {
  name     = "${var.resource_group_name}-secondary"
resource "azurerm_kubernetes_cluster" "di_primary" {
  name                = "aks-di-primary-${var.environment}"
  location            = azurerm_resource_group.rg_primary.location
  resource_group_name = azurerm_resource_group.rg_primary.name
  dns_prefix          = "di-primary-${var.environment}"
  kubernetes_version  = "1.29"
  }
}

# ====================================
# Cluster 1: Primary DI Container Cluster
# ====================================

resource "azurerm_kubernetes_cluster" "di_primary" {
  name                = "aks-di-primary-${var.environment}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "di-primary-${var.environment}"
  kubernetes_version  = "1.29"

  default_node_pool {
    name            = "default"
    node_count      = 2
    vm_size         = "Standard_D4s_v3" # 4 vCPUs, 16 GB RAM - minimum for DI workloads
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
    network_plugin      = "cilium"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    ebpf_data_plane     = "cilium"
    service_cidr        = "10.0.0.0/16"
    dns_service_ip      = "10.0.0.10"
    docker_bridge_cidr  = "172.17.0.1/16"
resource "azurerm_kubernetes_cluster" "di_secondary" {
  name                = "aks-di-secondary-${var.environment}"
  location            = azurerm_resource_group.rg_secondary.location
  resource_group_name = azurerm_resource_group.rg_secondary.name
  dns_prefix          = "di-secondary-${var.environment}"
  kubernetes_version  = "1.29"
  }
}
}

# ====================================
# Cluster 2: Secondary DI Container Cluster (DR)
# ====================================

resource "azurerm_kubernetes_cluster" "di_secondary" {
  name                = "aks-di-secondary-${var.environment}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "di-secondary-${var.environment}"
  kubernetes_version  = "1.29"

  default_node_pool {
    name            = "default"
    node_count      = 2
    vm_size         = "Standard_D4s_v3" # 4 vCPUs, 16 GB RAM - minimum for DI workloads
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
    network_plugin      = "cilium"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    ebpf_data_plane     = "cilium"
    service_cidr        = "10.1.0.0/16"
    dns_service_ip      = "10.1.0.10"
    docker_bridge_cidr  = "172.18.0.1/16"
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

provider "helm" {
  alias = "primary"

  kubernetes {
    host                   = azurerm_kubernetes_cluster.di_primary.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.di_primary.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.di_primary.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.di_primary.kube_config[0].cluster_ca_certificate)
  }
}

provider "helm" {
  alias = "secondary"

  kubernetes {
    host                   = azurerm_kubernetes_cluster.di_secondary.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.di_secondary.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.di_secondary.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.di_secondary.kube_config[0].cluster_ca_certificate)
  }
}

# ====================================
# Hubble Helm Release - Primary Cluster
# ====================================

resource "helm_release" "hubble_primary" {
  provider   = helm.primary
  name       = "hubble"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  namespace  = "kube-system"
  version    = "1.15.0"

  set {
    name  = "hubble.enabled"
    value = "true"
  }

  set {
    name  = "hubble.relay.enabled"
    value = "true"
  }

  set {
    name  = "hubble.ui.enabled"
    value = "true"
  }

  set {
    name  = "prometheus.enabled"
    value = "true"
  }

  depends_on = [azurerm_kubernetes_cluster.di_primary]
}

# ====================================
# Hubble Helm Release - Secondary Cluster
# ====================================

resource "helm_release" "hubble_secondary" {
  provider   = helm.secondary
  name       = "hubble"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  namespace  = "kube-system"
  version    = "1.15.0"

  set {
    name  = "hubble.enabled"
    value = "true"
  }

  set {
    name  = "hubble.relay.enabled"
    value = "true"
  }

  set {
    name  = "hubble.ui.enabled"
    value = "true"
  }

  set {
    name  = "prometheus.enabled"
    value = "true"
  }

  depends_on = [azurerm_kubernetes_cluster.di_secondary]
}

# ====================================
# Namespace for DI Containers
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
# Secret for DI Credentials - Primary
# ====================================

resource "kubernetes_secret" "di_credentials_primary" {
  provider = kubernetes.primary

  metadata {
    name      = "di-credentials"
    namespace = kubernetes_namespace.di_primary.metadata[0].name
  }

  data = {
    "api-key"  = base64encode(var.document_intelligence_key)
    "endpoint" = base64encode(var.document_intelligence_endpoint)
  }

  depends_on = [kubernetes_namespace.di_primary]
}

# ====================================
# Secret for DI Credentials - Secondary
# ====================================

resource "kubernetes_secret" "di_credentials_secondary" {
  provider = kubernetes.secondary

  metadata {
    name      = "di-credentials"
    namespace = kubernetes_namespace.di_secondary.metadata[0].name
  }

  data = {
    "api-key"  = base64encode(var.document_intelligence_key)
    "endpoint" = base64encode(var.document_intelligence_endpoint)
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
      }

      spec {
        container {
          name  = "di-layout"
          image = "mcr.microsoft.com/azure-cognitive-services/form-recognizer/layout-4.0:latest"

          # Resource requirements per Azure documentation (8 cores, 16GB memory minimum)
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

          # Enable privileged mode for accessing cgroup v2 (required for Cilium)
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = false
          }
        }

        security_context {
          fs_group = 1000
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
        max_surge       = "1"
        max_unavailable = "1"
      }
    }
  }

  depends_on = [
    kubernetes_namespace.di_primary,
    kubernetes_secret.di_credentials_primary,
    helm_release.hubble_primary
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

    type = "LoadBalancer"
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
      }

      spec {
        container {
          name  = "di-layout"
          image = "mcr.microsoft.com/azure-cognitive-services/form-recognizer/layout-4.0:latest"

          # Resource requirements per Azure documentation (8 cores, 16GB memory minimum)
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

          # Enable privileged mode for accessing cgroup v2 (required for Cilium)
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = false
          }
        }

        security_context {
          fs_group = 1000
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
        max_surge       = "1"
        max_unavailable = "1"
      }
    }
  }

  depends_on = [
    kubernetes_namespace.di_secondary,
    kubernetes_secret.di_credentials_secondary,
    helm_release.hubble_secondary
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

    type = "LoadBalancer"
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
}

output "secondary_cluster_id" {
  description = "Secondary AKS cluster resource ID"
  value       = azurerm_kubernetes_cluster.di_secondary.id
}

output "primary_di_service_endpoint" {
  description = "Primary Document Intelligence service endpoint"
  value       = "kubectl get svc -n document-intelligence di-layout-service"
}

output "secondary_di_service_endpoint" {
  description = "Secondary Document Intelligence service endpoint"
  value       = "kubectl get svc -n document-intelligence di-layout-service"
}

output "hubble_ui_access_primary" {
  description = "Access Hubble UI on primary cluster"
  value       = "kubectl -n kube-system port-forward svc/hubble-ui 8081:80"
}

output "hubble_ui_access_secondary" {
  description = "Access Hubble UI on secondary cluster"
  value       = "kubectl -n kube-system port-forward svc/hubble-ui 8081:80"
}
