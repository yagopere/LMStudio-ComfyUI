#!/bin/bash
# =============================================================================
# Простой скрипт создания LXC с ComfyUI + Flux + LM Studio
# Без танцев — всё ставится автоматически
# =============================================================================
set -euo pipefail

# === НАСТРОЙКИ ===
CTID=200
STORAGE="zpool-storage"           # твоё большое хранилище
RAM=16384                         # 16 GB
CPU_CORES=8
DISK_SIZE=128                     # ГБ
TEMPLATE_FAMILY="ubuntu-24.04"    # семейство шаблона

# === Автоматический поиск самого свежего шаблона ===
echo "=== Обновление списка шаблонов ==="
pveam update

LATEST_TEMPLATE=$(pveam available | grep -oP "${TEMPLATE_FAMILY}-standard_${TEMPLATE_FAMILY}-\d+-\d+_amd64\.tar\.zst" | sort -V | tail -1)

if [ -z "$LATEST_TEMPLATE" ]; then
    echo "Ошибка: не найден шаблон ${TEMPLATE_FAMILY}"
    pveam available | grep ubuntu-24.04
    exit 1
fi

echo "Используется шаблон: $LATEST_TEMPLATE"

TEMPLATE_FULL="${STORAGE}:vztmpl/${LATEST_TEMPLATE}"

# === Проверка места ===
FREE_KB=$(pvesm free "${STORAGE}" | awk '{print $1}')
MIN_KB=$((DISK_SIZE * 1024 * 1024 + 10 * 1024 * 1024))  # +10 ГБ запас
if [ "$FREE_KB" -lt "$MIN_KB" ]; then
    echo "Недостаточно места на ${STORAGE}: $((FREE_KB/1024/1024)) ГБ свободно, нужно ${DISK_SIZE}+ ГБ"
    exit 1
fi

# === Создание контейнера ===
echo "=== Создание контейнера ${CTID} ==="
pct create ${CTID} "${TEMPLATE_FULL}" \
    --hostname comfyui-flux \
    --memory ${RAM} \
    --cores ${CPU_CORES} \
    --rootfs "${STORAGE}:${DISK_SIZE}" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --features nesting=1,keyctl=1 \
    --unprivileged 0  # unprivileged=0 — проще для GPU и Docker

# === GPU passthrough (NVIDIA) ===
echo "=== Добавление GPU passthrough ==="
cat <<EOF >> /etc/pve/lxc/${CTID}.conf
lxc.cgroup2.devices.allow: a
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF

# === Запуск и установка ===
echo "=== Запуск контейнера и установка ==="
pct start ${CTID}

pct exec ${CTID} -- bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive

# Фикс локалей сразу
apt update
apt install -y locales
echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8

apt upgrade -y
apt install -y git python3 python3-venv python3-pip wget aria2 curl tmux htop sudo

adduser --disabled-password --gecos '' user
adduser user sudo
echo 'user ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/user

su - user -c '
set -e
cd ~

# ComfyUI
git clone https://github.com/comfyanonymous/ComfyUI.git
cd ComfyUI
python3 -m venv venv
source venv/bin/activate
pip install torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cpu
pip install -r requirements.txt

# Custom nodes
mkdir -p custom_nodes
cd custom_nodes
git clone https://github.com/ltdrdata/ComfyUI-Manager.git
git clone https://github.com/burnsbert/ComfyUI-EBU-LMStudio.git
git clone https://github.com/rgthree/rgthree-comfy.git

# Модели Flux (скачивание через huggingface_hub)
pip install -U huggingface_hub
python -c \"from huggingface_hub import login; login()\"  # введи токен один раз

# Скачивание моделей
python -c \"from huggingface_hub import hf_hub_download; hf_hub_download(repo_id='comfyanonymous/flux1-dev-fp8', filename='flux1-dev-fp8.safetensors', local_dir='models/checkpoints')\"
python -c \"from huggingface_hub import hf_hub_download; hf_hub_download(repo_id='comfyanonymous/flux_text_encoders', filename='t5xxl_fp8_e4m3fn.safetensors', local_dir='models/clip')\"
python -c \"from huggingface_hub import hf_hub_download; hf_hub_download(repo_id='comfyanonymous/flux_text_encoders', filename='clip_l.safetensors', local_dir='models/clip')\"
python -c \"from huggingface_hub import hf_hub_download; hf_hub_download(repo_id='black-forest-labs/FLUX.1-dev', filename='ae.safetensors', local_dir='models/vae')\"
'
"

echo "=== ГОТОВО! ==="
echo "Контейнер ${CTID} создан."
echo "Войди: pct enter ${CTID}"
echo "Затем: su - user"
echo "Залогинься в Hugging Face (если попросит): python -c \"from huggingface_hub import login; login()\""
echo "Запусти: ~/ComfyUI/venv/bin/python ~/ComfyUI/main.py --listen 0.0.0.0 --port 8188 --cpu"
echo "Интерфейс: http://IP_контейнера:8188"
echo "Удачи с Flux! 🚀"
