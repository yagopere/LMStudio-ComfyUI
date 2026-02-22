#!/bin/bash
# =============================================================================
# Самый простой и рабочий скрипт для ComfyUI + Flux + LM Studio
# Шаблон из системного кэша (local), диск на zpool-storage
# Фикс локалей, авторизация HF один раз, запуск в tmux
# =============================================================================
set -euo pipefail

CTID=200
STORAGE="zpool-storage"

echo "=== Проверка хранилища ==="
pvesm status | grep "$STORAGE" || { echo "Хранилище $STORAGE не найдено!"; exit 1; }

# Шаблон берём из системного кэша (как в твоём старом скрипте)
TEMPLATE="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"

if [ ! -f "/var/lib/vz/template/cache/$TEMPLATE" ]; then
    echo "Шаблон $TEMPLATE не найден. Скачиваем..."
    pveam update
    pveam download local "$TEMPLATE" || { echo "Не удалось скачать шаблон!"; exit 1; }
else
    echo "Шаблон $TEMPLATE уже есть — пропускаем скачивание"
fi

echo "=== Создание контейнера $CTID ==="
pct create "$CTID" "local:vztmpl/$TEMPLATE" \
    --hostname comfyui-flux \
    --memory 16384 \
    --cores 8 \
    --rootfs "$STORAGE:128" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --features nesting=1,keyctl=1 \
    --unprivileged 0

pct start "$CTID"

echo "=== Установка внутри контейнера ==="
pct exec "$CTID" -- bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y locales sudo git python3 python3-venv python3-pip wget curl tmux htop aria2

# Фикс локалей сразу
echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8

adduser --disabled-password --gecos '' user
adduser user sudo
echo 'user ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/user

su - user -c '
set -e
cd ~

git clone https://github.com/comfyanonymous/ComfyUI.git
cd ComfyUI
python3 -m venv venv
source venv/bin/activate
pip install -U pip setuptools wheel
pip install torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cpu
pip install -r requirements.txt

mkdir -p custom_nodes
cd custom_nodes
git clone https://github.com/ltdrdata/ComfyUI-Manager.git
git clone https://github.com/burnsbert/ComfyUI-EBU-LMStudio.git
git clone https://github.com/rgthree/rgthree-comfy.git

pip install -U huggingface_hub
python -c \"from huggingface_hub import login; login()\"  # Введи токен HF один раз!

python -c \"from huggingface_hub import hf_hub_download; hf_hub_download(repo_id='comfyanonymous/flux1-dev-fp8', filename='flux1-dev-fp8.safetensors', local_dir='models/checkpoints')\"
python -c \"from huggingface_hub import hf_hub_download; hf_hub_download(repo_id='comfyanonymous/flux_text_encoders', filename='t5xxl_fp8_e4m3fn.safetensors', local_dir='models/clip')\"
python -c \"from huggingface_hub import hf_hub_download; hf_hub_download(repo_id='comfyanonymous/flux_text_encoders', filename='clip_l.safetensors', local_dir='models/clip')\"
python -c \"from huggingface_hub import hf_hub_download; hf_hub_download(repo_id='black-forest-labs/FLUX.1-dev', filename='ae.safetensors', local_dir='models/vae')\"
'
"

echo "=== ГОТОВО! ==="
echo "Контейнер $CTID создан."
echo "Войди: pct enter $CTID"
echo "Затем: su - user"
echo "Запусти ComfyUI: cd ~/ComfyUI && source venv/bin/activate && python main.py --listen 0.0.0.0 --port 8188 --cpu"
echo "Интерфейс: http://IP_контейнера:8188"
echo "Готово! 🚀"
