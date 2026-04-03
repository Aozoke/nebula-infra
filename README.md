# Nebula Infra

Infrastructure Terraform pour reconstruire un cluster Nebula sur Proxmox de façon lisible et reproductible.

Le dépôt fait trois choses :
- crée 3 VM Ubuntu avec IP fixes
- installe Docker sur chaque VM
- bootstrappe le cluster : Docker Swarm, dépôt applicatif, build des images, déploiement Nebula, Portainer, puis monitoring en option

## Architecture

Le cluster repose sur trois VM :
- `vm1-lefevret` : nœud applicatif
- `vm2-lefevret` : manager Swarm et nœud edge
- `vm3-lefevret` : nœud data

Plan réseau :
- sous-réseau : `10.100.9.0/24`
- gateway : `10.100.9.254`
- DNS : `10.100.9.254`, `1.1.1.1`
- `vm1` : `10.100.9.230`
- `vm2` : `10.100.9.219`
- `vm3` : `10.100.9.231`

## Fichiers

- [versions.tf](./versions.tf) : versions Terraform et providers
- [provider.tf](./provider.tf) : provider Proxmox
- [main.tf](./main.tf) : définition des VM
- [bootstrap.tf](./bootstrap.tf) : installation Docker et bootstrap du cluster
- [scripts/bootstrap/prepull-service-images.sh.tftpl](./scripts/bootstrap/prepull-service-images.sh.tftpl) : précharge les images utiles
- [scripts/bootstrap/cluster-bootstrap.sh.tftpl](./scripts/bootstrap/cluster-bootstrap.sh.tftpl) : initialise Swarm et déploie Nebula
- [scripts/bootstrap/monitoring-bootstrap.sh.tftpl](./scripts/bootstrap/monitoring-bootstrap.sh.tftpl) : déploie Grafana / Prometheus / node-exporter

## Fonctionnement

Le flux Terraform est volontairement simple :

1. création des VM sur Proxmox
2. installation de Docker sur les 3 VM
3. copie de la clé SSH vers le manager
4. préchargement des images Docker utiles pour éviter les blocages de pull
5. bootstrap du cluster :
   - `swarm init` sur `vm2`
   - `swarm join` sur `vm1` et `vm3`
   - clone du dépôt `nebula-infra-swarm`
   - build des images applicatives sur `vm1`
   - déploiement de Nebula et Portainer depuis `vm2`
6. déploiement optionnel du monitoring

## Variables utiles

Variables Proxmox via l’environnement :

```powershell
$env:PROXMOX_VE_ENDPOINT = "https://IP-OU-DNS-PROXMOX:8006/"
$env:PROXMOX_VE_API_TOKEN = "USER@REALM!TOKENID=SECRET"
$env:PROXMOX_VE_INSECURE = "true"
```

Variables Terraform :
- `TF_VAR_openwrt_password` : mot de passe root OpenWrt utilisé comme bastion SSH
- `TF_VAR_enable_cluster_bootstrap` : active le bootstrap complet du cluster
- `TF_VAR_enable_monitoring_deploy` : active le monitoring
- `TF_VAR_nebula_postgres_password` : secret Postgres
- `TF_VAR_grafana_admin_password` : secret Grafana

## Utilisation

### Initialisation

```powershell
terraform init
terraform validate
```

### Déploiement des VM + Docker uniquement

```powershell
$pw = Read-Host "Mot de passe OpenWrt"
$env:TF_VAR_openwrt_password = $pw

terraform apply
```

### Déploiement complet du cluster

```powershell
$pw = Read-Host "Mot de passe OpenWrt"
$env:TF_VAR_openwrt_password = $pw
$env:TF_VAR_enable_cluster_bootstrap = "true"
$env:TF_VAR_nebula_postgres_password = "CHANGE_ME_DB_PASSWORD"

terraform apply
```

### Monitoring en option

```powershell
$env:TF_VAR_enable_monitoring_deploy = "true"
$env:TF_VAR_grafana_admin_password = "CHANGE_ME_GRAFANA_PASSWORD"

terraform apply
```

### Reconstruction complète

```powershell
terraform destroy
terraform apply
```

Pour une reconstruction complète avec bootstrap :

```powershell
$pw = Read-Host "Mot de passe OpenWrt"
$env:TF_VAR_openwrt_password = $pw
$env:TF_VAR_enable_cluster_bootstrap = "true"
$env:TF_VAR_nebula_postgres_password = "CHANGE_ME_DB_PASSWORD"
$env:TF_VAR_enable_monitoring_deploy = "true"
$env:TF_VAR_grafana_admin_password = "CHANGE_ME_GRAFANA_PASSWORD"

terraform destroy
terraform apply
```

## Vérifications

Depuis `vm2` :

```bash
docker node ls
docker stack services nebula
docker stack services portainer
docker stack services monitoring
docker secret ls
```

## Points d’attention

- le dépôt `nebula-infra-swarm` doit être accessible en lecture
- le bastion OpenWrt doit être joignable
- le bootstrap s’appuie sur des images publiques avec fallback vers `public.ecr.aws` et `quay.io` pour limiter les rate limits Docker Hub
- le monitoring reste optionnel pour garder un chemin de base simple

## Résultat attendu

À la fin d’un `terraform apply` complet :
- les 3 VM existent avec les bonnes IP
- Docker est installé partout
- `vm2` est leader Swarm
- `vm1` et `vm3` ont rejoint le cluster
- Nebula est déployée
- Portainer est disponible
- Grafana / Prometheus sont disponibles si le monitoring a été activé
