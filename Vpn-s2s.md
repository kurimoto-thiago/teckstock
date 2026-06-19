# Guia do Aluno — VPN Site-to-Site: AWS ↔ Azure
**Grafana · Prometheus · Power BI + RDS PostgreSQL**

---

> **O que você vai fazer:** configurar um túnel VPN IPsec entre a sua VPC na AWS (us-east-1) e o seu Resource Group no Azure. Com o túnel ativo, instalar Grafana + Prometheus em uma VM Linux no Azure e conectar o Power BI Desktop ao seu banco de dados RDS PostgreSQL — tudo trafegando pelo túnel, sem expor o banco à internet.

---

## Dados do seu ambiente (preencher antes de começar)

| Dado | Valor |
|---|---|
| Login Azure | `grupo-XX@<dominio>.onmicrosoft.com` |
| Resource Group Azure | `rg-sandbox-turma-<turno>-g<N>` |
| CIDR do seu Spoke Azure | `10.X.0.0/24` — informado pelo professor |
| IP público do vpngw-hub | informado pelo professor |
| CIDR da sua VPC AWS | ex: `172.31.0.0/16` — verificar no Console AWS |
| Endpoint do RDS | `<nome>.xxxx.us-east-1.rds.amazonaws.com` |
| Usuário/senha do RDS | |

> ⚠️ **Confirme com o professor o IP do `vpngw-hub` e o CIDR do seu Spoke antes de começar.** Esses dois valores são únicos por grupo — usar o valor errado derruba o túnel de outro grupo.

---

## Parte 1 — Configuração no lado AWS

### 1.1 Verificar a VPC

Console AWS > **VPC** > **Your VPCs**. Confirme que a sua VPC existe e anote o CIDR dela.

| O que verificar | Onde |
|---|---|
| CIDR da VPC | Coluna "IPv4 CIDR" |
| VPC ID | Coluna "VPC ID" — anote para os próximos passos |

> ℹ️ O CIDR da sua VPC não pode ser igual ao de outro grupo. Se a VPC foi criada com o padrão da AWS (`172.31.0.0/16`) e outro grupo usa o mesmo range, fale com o professor antes de continuar.

---

### 1.2 Criar o Virtual Private Gateway (VGW)

Console AWS > **VPC** > **Virtual Private Gateways** > **Create virtual private gateway**

| Campo | Valor |
|---|---|
| Name tag | `vgw-grupo-<N>` |
| ASN | Amazon default ASN (64512) |

Após criar: selecione o VGW > **Actions** > **Attach to VPC** > selecionar a sua VPC.

> ⚠️ Aguardar status **attached** antes de continuar.

---

### 1.3 Habilitar Route Propagation na Route Table

Console AWS > **VPC** > **Route Tables** > selecionar a route table da sua VPC (main ou a associada às subnets).

Aba **Route Propagation** > **Edit route propagation** > marcar o VGW criado no passo 1.2 > **Save**.

Isso faz o Azure anunciar automaticamente o CIDR do Spoke para as suas instâncias AWS via túnel.

---

### 1.4 Criar o Customer Gateway (CGW)

Console AWS > **VPC** > **Customer Gateways** > **Create customer gateway**

| Campo | Valor |
|---|---|
| Name tag | `cgw-azure-hub` |
| Routing | Static |
| IP Address | IP público do `vpngw-hub` ← informado pelo professor |
| BGP ASN | 65000 (não importa — BGP não está habilitado no Azure) |

---

### 1.5 Criar a VPN Connection

Console AWS > **VPC** > **Site-to-Site VPN Connections** > **Create VPN connection**

| Campo | Valor |
|---|---|
| Name tag | `vpn-aws-azure-grupo-<N>` |
| Target gateway type | Virtual private gateway |
| Virtual private gateway | `vgw-grupo-<N>` (criado no 1.2) |
| Customer gateway | Existing > `cgw-azure-hub` (criado no 1.4) |
| Routing options | Static |
| Static IP prefixes | CIDR do seu Spoke Azure — ex: `10.X.0.0/24` |
| Tunnel inside IP version | IPv4 |

Clicar em **Create VPN connection**. O provisionamento leva 1–5 minutos.

---

### 1.6 Baixar a configuração do túnel

Com a VPN Connection criada (status "pending" ou "available"):

1. Selecionar a VPN Connection criada.
2. Clicar em **Download configuration**.
3. Vendor: **Generic** / Platform: **Generic** / Software: **Vendor Agnostic**.
4. Clicar em **Download**.

Do arquivo baixado, anote:

| Informação | Onde no arquivo | Valor |
|---|---|---|
| Outside IP address — Tunnel 1 | Seção "IPSec Tunnel #1" > "Outside IP Addresses" > "Virtual Private Gateway" | |
| Pre-Shared Key — Tunnel 1 | Seção "IPSec Tunnel #1" > "Pre-Shared Key" | |

> ℹ️ **Apenas o Tunnel 1 é necessário.** O Azure usa um único túnel ativo por Connection. Configure o Tunnel 1 e ignore o Tunnel 2.

---

### 1.7 Liberar o Security Group do RDS

Para o Power BI conseguir atingir o RDS pelo túnel, o Security Group do RDS precisa aceitar conexões na porta 5432 vindas do CIDR do seu Spoke Azure.

Console AWS > **EC2** > **Security Groups** > selecionar o SG associado ao RDS > **Inbound rules** > **Edit inbound rules** > **Add rule**:

| Campo | Valor |
|---|---|
| Type | PostgreSQL |
| Protocol | TCP |
| Port range | 5432 |
| Source | CIDR do seu Spoke Azure — ex: `10.X.0.0/24` |
| Description | VPN Azure Spoke grupo N |

---

## Parte 2 — Configuração no lado Azure

### 2.1 Fazer login no Portal Azure

Acesse **https://portal.azure.com** e entre com o login do seu grupo.

Você verá apenas o Resource Group do seu grupo. Isso é esperado — sua conta tem acesso restrito ao seu ambiente.

---

### 2.2 Criar o Local Network Gateway

O Local Network Gateway representa o lado AWS do túnel (é como o Azure "enxerga" a sua VPC).

Portal > **Resource groups** > `rg-sandbox-<grupo>` > **+ Create** > buscar **"Local network gateway"** > **Create**

| Campo | Valor |
|---|---|
| Name | `lng-aws-grupo-<N>` |
| Endpoint | IP address |
| IP address | Outside IP do Tunnel 1 ← do arquivo AWS (passo 1.6) |
| Address space | CIDR da sua VPC AWS — ex: `172.31.0.0/16` |
| Resource group | `rg-sandbox-<grupo>` |
| Location | East US |
| Configure BGP settings | Não marcar |

**Review + Create** > **Create**. Aguardar a implantação (~30 s).

---

### 2.3 Criar a Connection (túnel IPsec)

A Connection é o túnel propriamente dito — une o VPN Gateway do hub (compartilhado) ao Local Network Gateway que você criou.

Portal > **Resource groups** > `rg-sandbox-<grupo>` > **+ Create** > buscar **"Connection"** > **Create**

| Campo | Valor |
|---|---|
| Connection type | Site-to-site (IPsec) |
| Name | `conn-aws-grupo-<N>` |
| Region | East US |
| Virtual network gateway | `vpngw-hub` ← gateway compartilhado do professor |
| Local network gateway | `lng-aws-grupo-<N>` ← criado no passo 2.2 |
| Shared key (PSK) | Pre-Shared Key do Tunnel 1 ← do arquivo AWS (passo 1.6) |
| IKE Protocol | IKEv2 |
| Resource group | `rg-sandbox-<grupo>` |

**Review + Create** > **Create**.

> ℹ️ O campo "Virtual network gateway" pode aparecer vazio se você digitar. Clique em **Browse virtual network gateways** e procure `vpngw-hub`. Você tem permissão Reader nele — pode selecionar, mas não alterar.

---

### 2.4 Verificar o status do túnel

Pode levar alguns minutos para o túnel negociar o IPsec nos dois lados.

1. Portal > **Resource groups** > `rg-sandbox-hub` > recurso `vpngw-hub` > **Connections**.
2. Localizar `conn-aws-grupo-<N>` — aguardar status **Connected** (2–5 minutos).
3. Console AWS > **VPC** > **Site-to-Site VPN Connections** > **Tunnel details** > Tunnel 1 deve mostrar **UP**.

> ⚠️ Se o Tunnel 1 ficar DOWN por mais de 10 minutos, verifique se a PSK foi copiada corretamente nos dois lados.

---

## Parte 3 — VM Linux (Grafana + Prometheus)

### 3.1 Criar NSG

Portal > `rg-sandbox-<grupo>` > **+ Create** > **"Network security group"** > **Create**

- Nome: `nsg-vm-grupo-<N>` | Resource group: `rg-sandbox-<grupo>` | Region: East US

Após criar, adicionar regras de **Inbound**:

| Porta | Protocolo | Source | Finalidade |
|---|---|---|---|
| 22 | TCP | Seu IP público (whatismyip.com) | SSH — remover após configurar a VM |
| 3000 | TCP | Seu IP público | Grafana |
| 9090 | TCP | Seu IP público | Prometheus |

> ⚠️ **Nunca abrir Source `0.0.0.0/0`.** Isso expõe a VM a toda a internet. Use sempre o IP do seu grupo ou da escola.

---

### 3.2 Criar a VM Linux

Portal > `rg-sandbox-<grupo>` > **+ Create** > **Virtual Machine** > **Create**

**Aba Basics:**

| Campo | Valor |
|---|---|
| Resource group | `rg-sandbox-<grupo>` |
| Virtual machine name | `vm-grafana-grupo-<N>` |
| Region | East US |
| Image | Ubuntu Server 24.04 LTS |
| Size | Standard_B1s (1 vCPU, 1 GB RAM) |
| Authentication type | SSH public key |
| Username | `azureuser` (ou outro de sua escolha) |
| Inbound ports | None (NSG vai na NIC, não aqui) |

**Aba Networking:**

| Campo | Valor |
|---|---|
| Virtual network | `vnet-<grupo>` (já existe — criado pelo professor) |
| Subnet | `snet-<grupo>` (já existe) |
| Public IP | Create new → nome: `pip-vm-grupo-<N>` |
| NIC network security group | Advanced > selecionar `nsg-vm-grupo-<N>` |

> ℹ️ **NSG na NIC, não na subnet.** Sua conta não tem permissão de escrita na subnet (gerenciada pelo professor). Associe o NSG na NIC durante a criação da VM, no campo acima.

> ℹ️ **Chave SSH — duas opções:**
> - **Opção A (recomendada):** selecionar **Generate new key pair** — o Portal gera e salva a chave no seu RG automaticamente (sua conta tem permissão para isso).
> - **Opção B:** gerar localmente e colar a chave pública:
>   ```bash
>   ssh-keygen -t rsa -b 4096 -f ~/.ssh/azure-grupo-N
>   # Colar o conteúdo de ~/.ssh/azure-grupo-N.pub no campo SSH public key
>   ```

**Aba Management:**

| Campo | Valor |
|---|---|
| Boot diagnostics | **Disable** ← obrigatório |
| Auto-shutdown | Enable |
| Shutdown time | Horário de fim da aula do seu turno |

> ⚠️ **Boot diagnostics deve ser desabilitado.** O recurso usa Storage Account, para o qual sua conta não tem permissão. Se deixar habilitado, o deploy da VM vai falhar.

**Review + Create** > **Create**.

---

### 3.3 Conectar via SSH

Após o deploy (~2 min), obter o IP público da VM:

Portal > **`vm-grafana-grupo-<N>`** > **Connect** > **SSH** — copiar o comando:

```bash
ssh -i <caminho-da-chave.pem> azureuser@<IP-PUBLICO-DA-VM>
```

---

### 3.4 Instalar Prometheus

```bash
# Baixar e extrair
cd ~
wget https://github.com/prometheus/prometheus/releases/download/v2.49.0/prometheus-2.49.0.linux-amd64.tar.gz
tar xvf prometheus-2.49.0.linux-amd64.tar.gz
sudo mv prometheus-2.49.0.linux-amd64 /opt/prometheus

# Criar serviço systemd
sudo tee /etc/systemd/system/prometheus.service <<EOF
[Unit]
Description=Prometheus
After=network.target

[Service]
ExecStart=/opt/prometheus/prometheus \
  --config.file=/opt/prometheus/prometheus.yml \
  --storage.tsdb.path=/opt/prometheus/data
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now prometheus
sudo systemctl status prometheus
```

Verificar: abrir **`http://<IP-DA-VM>:9090`** no navegador.

---

### 3.5 Instalar Grafana

```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https software-properties-common wget

sudo mkdir -p /etc/apt/keyrings/
wget -q -O - https://apt.grafana.com/gpg.key | \
  gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null

echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] \
  https://apt.grafana.com stable main" | \
  sudo tee /etc/apt/sources.list.d/grafana.list

sudo apt-get update
sudo apt-get install -y grafana

sudo systemctl enable --now grafana-server
sudo systemctl status grafana-server
```

Verificar: abrir **`http://<IP-DA-VM>:3000`** no navegador. Login padrão: `admin` / `admin` — troque na primeira vez.

---

## Parte 4 — Power BI Desktop + RDS PostgreSQL via túnel

### 4.1 Pré-requisitos

- Power BI Desktop instalado (Windows — download gratuito em powerbi.microsoft.com).
- Túnel VPN ativo — status Connected no Azure e UP na AWS (confirmado no passo 2.4).
- Security Group do RDS liberado para o Spoke Azure (passo 1.7).

---

### 4.2 Instalar o driver npgsql (se necessário)

O Power BI Desktop precisa do driver npgsql para conectar ao PostgreSQL. Se já estiver instalado, pule este passo.

1. Acessar https://github.com/npgsql/npgsql/releases
2. Baixar `Npgsql<versão>_win-x64.msi`
3. Executar o instalador. Reiniciar o Power BI Desktop após a instalação.

---

### 4.3 Conectar ao RDS PostgreSQL

1. Power BI Desktop > **Get Data** > **More...**
2. Pesquisar **"PostgreSQL"** > selecionar **PostgreSQL database** > **Connect**
3. Preencher:

| Campo | Valor |
|---|---|
| Server | `<endpoint-do-rds>:5432` — ex: `mydb.xxxx.us-east-1.rds.amazonaws.com:5432` |
| Database | Nome do banco de dados |

4. **OK** > autenticar com usuário/senha do banco > selecionar modo Import ou DirectQuery.
5. Selecionar as tabelas/views desejadas > **Load**.

> ℹ️ **O tráfego passa pelo túnel VPN.** O endpoint do RDS é um nome DNS privado da AWS. O Power BI Desktop resolve esse nome via túnel — não é necessário nenhum redirecionamento de porta nem IP público do banco.

> ⚠️ **Se a conexão falhar:**
> 1. Confirmar que o túnel está UP nos dois lados (passo 2.4).
> 2. Confirmar que o Security Group do RDS libera a porta 5432 para o CIDR do Spoke Azure.
> 3. O RDS com "Publicly accessible = No" resolve para IP privado — isso é correto e só é alcançável pelo túnel.

---

## Checklist de entrega

Marque cada item antes de submeter o projeto:

| # | Item | ✓ |
|---|---|---|
| 1 | VPN Connection no Azure com status Connected | ☐ |
| 2 | Tunnel 1 na AWS com status UP | ☐ |
| 3 | VM Linux criada no Resource Group do grupo | ☐ |
| 4 | Prometheus respondendo em `http://<IP-VM>:9090` | ☐ |
| 5 | Grafana respondendo em `http://<IP-VM>:3000` | ☐ |
| 6 | Power BI Desktop conectado ao RDS PostgreSQL via túnel (tabelas visíveis) | ☐ |
| 7 | NSG com regras restritas (sem `0.0.0.0/0`) | ☐ |
| 8 | Auto-shutdown configurado na VM | ☐ |
| 9 | Screenshot do dashboard Grafana com dados do Prometheus | ☐ |
| 10 | Screenshot do Power BI com dados do RDS | ☐ |

---

> 📌 **Dúvidas ou erros?** Verifique a seção de Troubleshooting no README do projeto (entregue pelo professor) ou entre em contato com o professor antes de refazer passos — a maioria dos erros tem causa identificável.
