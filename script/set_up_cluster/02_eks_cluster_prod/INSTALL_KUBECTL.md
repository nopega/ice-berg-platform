# ติดตั้ง eksctl และ kubectl

ทั้งสองตัวจำเป็นก่อนรัน `02_create_eks_cluster_prod.sh` — `eksctl` สร้าง cluster, `kubectl` ใช้คุยกับ cluster หลังสร้างเสร็จ

## macOS

```bash
brew tap weaveworks/tap
brew install weaveworks/tap/eksctl
brew install kubectl

eksctl version
kubectl version --client
```

## Linux

```bash
# eksctl
ARCH=amd64   # เครื่อง ARM (เช่น Graviton) เปลี่ยนเป็น arm64
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_${ARCH}.tar.gz"
tar -xzf "eksctl_Linux_${ARCH}.tar.gz" -C /tmp && rm "eksctl_Linux_${ARCH}.tar.gz"
sudo mv /tmp/eksctl /usr/local/bin/

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

eksctl version
kubectl version --client
```

## ตรวจว่าใช้งานได้

```bash
eksctl version
kubectl version --client
```

ควรเห็นเลขเวอร์ชันทั้งคู่ — ต่อ cluster จริงยังไม่ได้จนกว่าจะรัน `./02_create_eks_cluster_prod.sh` ให้เสร็จก่อน เพราะ `eksctl` จะเขียน kubeconfig ให้ `kubectl` ใช้เองอัตโนมัติตอนสร้าง cluster สำเร็จ ไม่ต้องตั้งค่าอะไรเพิ่ม
