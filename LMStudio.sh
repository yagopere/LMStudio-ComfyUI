#!/bin/bash

# ================================================
# Скрипт создания LXC с ComfyUI + Flux + LM Studio в Proxmox
# Аналог твоего ollama-openwebui-lxc, но для Flux + GPT-OSS через LM Studio
# ================================================

set -e

# =========== НАСТРОЙКИ — ИЗМЕНИ ПОД СЕБЯ ===========
CTID=200                # ID контейнера (выбери свободный, например 200)
CT_NAME="comfyui-flux-lmstudio"
HOSTNAME="comfyui-flux"
RAM=16384               # MB (16 GB рекомендуется для Flux dev)
SWAP=8192               # MB
DISK_SIZE=64            # GB
CPU_CORES=8             # Количество ядер
TEMPLATE="local:vztmpl/ubuntu-24.04-standard_24.04-1_amd64.tar.zst"  # Проверь актуальный в pveam available
IP_ADDRESS="192.168.1.200/24"   # Измени на свой подсеть
GATEWAY="192.168.1.1"
BRIDGE="vmbr0"
GPU_PASSTHROUGH=true    # true если NVIDIA GPU, false если CPU-only
# ================================================

echo "=== Создание LXC контейнера $CTID ($CT_NAME) ==="
pct create $CTID $TEMPLATE \
    --hostname $HOSTNAME \
    --memory $RAM \
    --swap $SWAP \
    --cores $CPU_CORES \
    --rootfs local-lvm:$DISK_SIZE \
    --net0 name=eth0,bridge=$BRIDGE,ip=$IP_ADDRESS,gw=$GATEWAY \
    --features nesting=1,keyctl=1 \
    --unprivileged 1

echo "=== Настройка GPU passthrough (если включено) ==="
if [ "$GPU_PASSTHROUGH" = true ]; then
    mkdir -p /etc/pve/lxc/$CTID.conf
    cat <<EOF >> /etc/pve/lxc/$CTID.conf
lxc.cgroup2.devices.allow: a
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidia1 dev/nvidia1 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
EOF
    echo "GPU passthrough настроен (все устройства NVIDIA проброшены)"
fi

echo "=== Запуск контейнера и настройка внутри ==="
pct start $CTID

pct exec $CTID -- bash -c "
set -e

export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y
apt install -y git python3 python3-venv python3-pip wget aria2 curl tmux htop

# Если GPU — установка CUDA внутри не нужна (используем хостовый драйвер), но torch с CUDA
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
if command -v nvidia-smi > /dev/null; then
    pip install torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cu121
    echo \"CUDA обнаружен — установлен torch с CUDA\"
else
    pip install torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cpu
    echo \"CPU-only режим\"
fi
pip install -r requirements.txt

echo \"=== Custom nodes ===\"
mkdir -p custom_nodes
cd custom_nodes
git clone https://github.com/ltdrdata/ComfyUI-Manager.git
git clone https://github.com/burnsbert/ComfyUI-EBU-LMStudio.git   # Для интеграции с LM Studio (system prompt!)
git clone https://github.com/rgthree/rgthree-comfy.git           # Power LoRA Loader — удобно для Flux LoRA

echo \"=== Скачивание моделей Flux.1 dev FP8 ===\"
cd ~/ComfyUI
mkdir -p models/checkpoints models/clip models/vae models/loras

aria2c -x 16 'https://huggingface.co/comfyanonymous/flux1-dev-fp8/resolve/main/flux1-dev-fp8.safetensors' -o models/checkpoints/flux1-dev-fp8.safetensors
aria2c 'https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors' -o models/clip/t5xxl_fp8_e4m3fn.safetensors
aria2c 'https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors' -o models/clip/clip_l.safetensors
aria2c 'https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/ae.safetensors' -o models/vae/flux_ae.safetensors

echo \"=== Подготовка для LM Studio ===\"
mkdir -p ~/LMStudio
echo \"Скачай LM Studio AppImage с https://lmstudio.ai и положи в /home/user/LMStudio/LM_Studio.AppImage\" > ~/LMStudio/README.txt
echo \"Загрузи модель GPT-OSS (например Llama-3.1-70B или любую GGUF) через GUI\" >> ~/LMStudio/README.txt
echo \"Включи Local Server на порту 1234\" >> ~/LMStudio/README.txt

echo \"=== Сервис автозапуска ComfyUI ===\"
cat <<'EOF' > ~/start_comfyui.sh
#!/bin/bash
cd ~/ComfyUI
source venv/bin/activate
python main.py --listen 0.0.0.0 --port 8188
EOF
chmod +x ~/start_comfyui.sh

cat <<'EOF' > ~/start_all.sh
#!/bin/bash
tmux new-session -d -s ai_stack
tmux send-keys -t ai_stack:0 'echo \"Запусти LM Studio GUI и включи сервер на 1234\"' C-m
tmux split-window -h
tmux send-keys -t ai_stack:1 '~/start_comfyui.sh' C-m
tmux split-window -v
tmux send-keys -t ai_stack:2 'htop' C-m
echo \"Запущено в tmux сессии ai_stack. Подключись: tmux attach -t ai_stack\"
EOF
chmod +x ~/start_all.sh

echo \"Готово! Войди в контейнер: pct enter $CTID\"
echo \"Затем: ./start_all.sh\"
echo \"ComfyUI будет на http://$IP_ADDRESS:8188 (пробрось порт в браузере или через прокси)\"
echo \"Для промптов с system prompt используй node EBU-LMStudio → укажи system prompt там\"
echo \"LoRA кидай в models/loras и используй Power LoRA Loader из rgthree\"
'
'

echo \"=== ВСЁ ГОТОВО! ===\"
echo \"Контейнер $CTID создан и настроен.\"
echo \"Войди: pct enter $CTID\"
echo \"Скачай LM Studio AppImage и положи в /home/user/LMStudio/\"
echo \"Запусти: ./start_all.sh\"
echo \"ComfyUI доступен по IP $IP_ADDRESS:8188\"
echo \"Наслаждайся Flux + LoRA + GPT-OSS с system prompt! 🚀\"
