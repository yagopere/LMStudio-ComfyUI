#!/bin/bash
# =============================================================================
# Скрипт создания LXC с ComfyUI + Flux + LM Studio в Proxmox
# Полностью независим от хранилища 'local'
# Автоматически скачивает самый свежий шаблон Ubuntu 24.04 в указанное хранилище
# =============================================================================
set -euo pipefail
trap 'echo "Ошибка на строке $LINENO"; exit 1' ERR

# =========== НАСТРОЙКИ — ИЗМЕНИ ПОД СЕБЯ ===========
CTID=200                          # ID контейнера (проверь свободный: pct list)
CT_NAME="comfyui-flux-lmstudio"
HOSTNAME="comfyui-flux"
RAM=16384                         # MB (16 GB минимум для Flux dev)
SWAP=8192                         # MB
DISK_SIZE=128                     # GB — Flux + модели + LM Studio легко занимают 80–120 ГБ
CPU_CORES=8                       # ядер
STORAGE="zpool-storage"           # твоё основное хранилище
# ================================================

echo "=== Проверка хранилища '${STORAGE}' ==="
if ! pvesm status | grep -q "^${STORAGE} "; then
    echo "ОШИБКА: Хранилище '${STORAGE}' не найдено или не активно!"
    echo "Доступные хранилища:"
    pvesm status
    exit 1
fi

if pvesm status | grep "^${STORAGE} " | grep -q "disabled"; then
    echo "ОШИБКА: Хранилище '${STORAGE}' отключено!"
    exit 1
fi

FREE_SPACE_KB=$(pvesm status | grep "^${STORAGE} " | awk '{print $5}')
MIN_SPACE_KB=$((DISK_SIZE * 1024 * 1024 + 1024 * 1024 * 10))  # +10 ГБ запас
if [ "$FREE_SPACE_KB" -lt "$MIN_SPACE_KB" ]; then
    echo "ВНИМАНИЕ: На хранилище ${STORAGE} свободно только $((FREE_SPACE_KB/1024/1024)) ГБ!"
    echo "Нужно минимум ${DISK_SIZE} ГБ + запас"
    read -p "Продолжить всё равно? (y/N): " answer
    [[ "$answer" != "y" && "$answer" != "Y" ]] && exit 1
fi

echo "=== Поиск и скачивание самого свежего шаблона Ubuntu 24.04 ==="
pveam update

# Ищем самый свежий шаблон Ubuntu 24.04
LATEST_TEMPLATE=$(pveam available | grep -o 'ubuntu-24.04-standard_24.04-[0-9]*_amd64.tar.zst' | sort -V | tail -1)

if [ -z "$LATEST_TEMPLATE" ]; then
    echo "ОШИБКА: Не удалось найти шаблон Ubuntu 24.04 в pveam available!"
    echo "Проверь репозитории: pveam available | grep ubuntu"
    exit 1
fi

echo "Самый свежий шаблон: $LATEST_TEMPLATE"

TEMPLATE_FULL="${STORAGE}:vztmpl/${LATEST_TEMPLATE}"

# Проверяем наличие в кэше хранилища
TEMPLATE_CACHE_PATH="/${STORAGE}/template/cache/${LATEST_TEMPLATE}"
if [ ! -f "${TEMPLATE_CACHE_PATH}" ]; then
    echo "Шаблон ${LATEST_TEMPLATE} не найден в ${STORAGE}. Скачиваем..."
    pveam download "${STORAGE}" "${LATEST_TEMPLATE}"
    if [ $? -ne 0 ]; then
        echo "Ошибка скачивания шаблона!"
        exit 1
    fi
    echo "Шаблон успешно скачан в ${STORAGE}"
else
    echo "Шаблон ${LATEST_TEMPLATE} уже присутствует в ${STORAGE}"
fi

echo "=== Создание LXC контейнера ${CTID} (${CT_NAME}) на хранилище ${STORAGE} ==="

pct create ${CTID} "${TEMPLATE_FULL}" \
    --hostname "${HOSTNAME}" \
    --memory ${RAM} \
    --swap ${SWAP} \
    --cores ${CPU_CORES} \
    --rootfs "${STORAGE}:${DISK_SIZE}" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --features nesting=1,keyctl=1 \
    --unprivileged 1

echo "=== Настройка GPU passthrough (если включено) ==="
if [ "${GPU_PASSTHROUGH:-false}" = true ]; then
    echo "lxc.cgroup.devices.allow: a" >> /etc/pve/lxc/${CTID}.conf
    echo "lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file" >> /etc/pve/lxc/${CTID}.conf
    echo "lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file" >> /etc/pve/lxc/${CTID}.conf
    echo "lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file" >> /etc/pve/lxc/${CTID}.conf
    echo "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir" >> /etc/pve/lxc/${CTID}.conf
    echo "GPU passthrough добавлен"
fi

echo "=== Запуск контейнера и базовая настройка ==="
pct start ${CTID}
pct exec ${CTID} -- bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y
apt install -y locales git python3 python3-venv python3-pip wget aria2 curl tmux htop sudo

# Фикс локалей сразу после установки
echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8

adduser --disabled-password --gecos '' user
adduser user sudo
echo 'user ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/user
su - user -c '
set -e
cd ~
echo \"=== Установка ComfyUI ===\"
git clone https://github.com/comfyanonymous/ComfyUI.git
cd ComfyUI
python3 -m venv venv
source venv/bin/activate
if command -v nvidia-smi >/dev/null 2>&1; then
    pip install torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cu121
else
    pip install torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cpu
fi
pip install -r requirements.txt
mkdir -p custom_nodes
cd custom_nodes
git clone https://github.com/ltdrdata/ComfyUI-Manager.git
git clone https://github.com/burnsbert/ComfyUI-EBU-LMStudio.git
git clone https://github.com/rgthree/rgthree-comfy.git
cd ~/ComfyUI
mkdir -p models/checkpoints models/clip models/vae models/loras
aria2c -x 16 https://huggingface.co/comfyanonymous/flux1-dev-fp8/resolve/main/flux1-dev-fp8.safetensors -o models/checkpoints/flux1-dev-fp8.safetensors
aria2c https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors -o models/clip/t5xxl_fp8_e4m3fn.safetensors
aria2c https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors -o models/clip/clip_l.safetensors
aria2c https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/ae.safetensors -o models/vae/flux_ae.safetensors
mkdir -p ~/LMStudio
echo \"Скачай LM Studio AppImage с https://lmstudio.ai\" > ~/LMStudio/README.txt
cat <<EOF > ~/start_comfyui.sh
#!/bin/bash
cd ~/ComfyUI
source venv/bin/activate
python main.py --listen 0.0.0.0 --port 8188
EOF
chmod +x ~/start_comfyui.sh
cat <<EOF > ~/start_all.sh
#!/bin/bash
tmux new-session -d -s ai_stack
tmux send-keys -t ai_stack:0 'echo \"Запусти LM Studio и включи сервер на 1234\"' C-m
tmux split-window -h
tmux send-keys -t ai_stack:1 '~/start_comfyui.sh' C-m
tmux split-window -v
tmux send-keys -t ai_stack:2 'htop' C-m
echo \"tmux attach -t ai_stack\"
EOF
chmod +x ~/start_all.sh
'
"

echo "=== УСПЕХ! ==="
echo "Контейнер ${CTID} создан на хранилище ${STORAGE}."
echo "Войди: pct enter ${CTID}"
echo "Затем от пользователя user: ~/start_all.sh"
echo "ComfyUI → http://IP_контейнера:8188"
echo "LM Studio → скачай AppImage и запусти внутри"
echo "Готово! 🚀"
