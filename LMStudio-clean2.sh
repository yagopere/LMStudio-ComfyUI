#!/usr/bin/env bash
# =============================================================================
# Скрипт создания LXC с ComfyUI + Flux fp8 + LM Studio в Proxmox
# Исправлено: su без -, + отключён set -u внутри
# =============================================================================

set -euo pipefail
trap 'echo "Ошибка на строке $LINENO"; exit 1' ERR

# =========== НАСТРОЙКИ ===========
CTID=200
CT_NAME="comfyui-flux-lm"
HOSTNAME="ai-flux"
RAM=24576
SWAP=8192
DISK_SIZE=160
CPU_CORES=10
STORAGE="zpool-storage"

GPU_PASSTHROUGH=false

# ================================================

echo "┌──────────────────────────────────────────────┐"
echo "│        Создание LXC • ComfyUI + Flux + LM    │"
echo "└──────────────────────────────────────────────┘"

# Проверка хранилища
echo "→ Проверка хранилища ${STORAGE} ..."
if ! pvesm status | grep -q "^${STORAGE} "; then
    echo "❌ Хранилище '${STORAGE}' не найдено!"
    pvesm status
    exit 1
fi

free_gb=$(pvesm status | grep "^${STORAGE} " | awk '{print int($5/1024/1024)}')
need_gb=$((DISK_SIZE + 30))
if (( free_gb < need_gb )); then
    echo "⚠️  Свободно ~${free_gb} ГБ (нужно ≥ ${need_gb} ГБ)"
    read -p "Продолжить? (y/N) " -n1 ans
    echo
    [[ "$ans" != "y" && "$ans" != "Y" ]] && exit 1
fi

# Шаблон Ubuntu 24.04
echo "→ Обновление списка шаблонов..."
pveam update >/dev/null

LATEST=$(pveam available | grep -oP 'ubuntu-24.04-standard_24.04-\d+_amd64\.tar\.zst' | sort -V | tail -1)

[[ -z "$LATEST" ]] && { echo "❌ Нет шаблона Ubuntu 24.04"; exit 1; }

TEMPLATE="${STORAGE}:vztmpl/${LATEST}"

if ! pvesm list "${STORAGE}" | grep -q "${LATEST}"; then
    pveam download "${STORAGE}" "${LATEST}"
fi

# Создание LXC
echo "→ Создаём LXC ${CTID} ..."
pct create "${CTID}" "${TEMPLATE}" \
    --hostname "${HOSTNAME}" \
    --memory "${RAM}" \
    --swap "${SWAP}" \
    --cores "${CPU_CORES}" \
    --rootfs "${STORAGE}:${DISK_SIZE}" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --features nesting=1,keyctl=1 \
    --unprivileged 1 \
    --start 1 2>/dev/null || true

sleep 5

# GPU (если нужно)
if [[ "${GPU_PASSTHROUGH}" = true ]]; then
    echo "→ GPU passthrough..."
    cat >> /etc/pve/lxc/"${CTID}".conf <<EOF
lxc.cgroup2.devices.allow: a
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF
fi

# Установка внутри
echo "→ Установка внутри LXC..."

pct exec "${CTID}" -- bash -c "
set -e -o pipefail
export DEBIAN_FRONTEND=noninteractive

apt update -qq && apt upgrade -y -qq
apt install -y -qq locales git python3 python3-venv python3-pip wget aria2 curl tmux htop sudo ca-certificates

echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8

adduser --disabled-password --gecos '' user
adduser user sudo
echo 'user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-user-nopasswd
chmod 0440 /etc/sudoers.d/99-user-nopasswd

su user -s /bin/bash -c '
set -e -o pipefail
# set -u отключён намеренно

cd ~

echo \"→ Установка ComfyUI ...\"
git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git
cd ComfyUI

python3 -m venv venv
source venv/bin/activate

if command -v nvidia-smi &>/dev/null; then
    pip install --upgrade pip
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124
else
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu
fi

pip install -r requirements.txt --no-cache-dir

mkdir -p custom_nodes
cd custom_nodes
git clone --depth=1 https://github.com/ltdrdata/ComfyUI-Manager.git
git clone --depth=1 https://github.com/rgthree/rgthree-comfy.git
cd ~/ComfyUI

mkdir -p models/checkpoints models/clip models/vae models/loras models/unet

echo \"→ Скачиваем Flux fp8 ...\"
aria2c -x16 -s16 --summary-interval=15 \
    \"https://huggingface.co/comfyanonymous/flux1-dev-fp8/resolve/main/flux1-dev-fp8.safetensors\" \
    -o models/checkpoints/flux1-dev-fp8.safetensors

aria2c -x8 \"https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors\" -o models/clip/t5xxl_fp8_e4m3fn.safetensors
aria2c -x8 \"https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors\" -o models/clip/clip_l.safetensors
aria2c -x8 \"https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/ae.safetensors\" -o models/vae/flux_ae.safetensors

mkdir -p ~/LMStudio
echo \"Скачай LM Studio AppImage с https://lmstudio.ai\" > ~/LMStudio/README.txt

cat > ~/start_comfyui.sh <<'E1'
#!/usr/bin/env bash
cd ~/ComfyUI
source venv/bin/activate
python main.py --listen 0.0.0.0 --port 8188 --enable-cors-header --auto-launch --preview-method auto
E1
chmod +x ~/start_comfyui.sh

cat > ~/start_all.sh <<'E2'
#!/usr/bin/env bash
tmux new-session -d -s ai
tmux send-keys -t ai:0 \"echo \\\"→ Запусти LM Studio и включи сервер (порт 1234)\\\"\" C-m
tmux split-window -h
tmux send-keys -t ai:1 \"~/start_comfyui.sh\" C-m
tmux split-window -v
tmux send-keys -t ai:2 \"htop\" C-m
tmux select-pane -t ai:0
echo \"\"
echo \"tmux attach -t ai\"
echo \"ComfyUI: http://\$(hostname -I | awk '{print \$1}'):8188\"
echo \"\"
E2
chmod +x ~/start_all.sh

echo \"Готово! Войди: pct enter ${CTID}\"
echo \"Запуск: ~/start_all.sh\"
'
"

echo "Контейнер готов."
echo "pct enter ${CTID}"
echo "su - user -c '~/start_all.sh'"
