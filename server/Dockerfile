# CUDA build by default. compose.yaml's `cpu` profile builds it with the CPU-only torch index
# instead, which makes a far smaller image for PCs without an NVIDIA GPU.
FROM python:3.12-slim

ARG TORCH_INDEX=https://download.pytorch.org/whl/cu128

# ffmpeg decodes the uploads (m4a, caf, wav, mp3…) and backs torchcodec.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
# WhisperX 3.8.6 pins torch 2.8. The cu128 wheels bring their own cuBLAS and cuDNN 9, which is
# also what CTranslate2 (faster-whisper) needs, so no CUDA base image is required.
RUN pip install --no-cache-dir torch==2.8.0 torchaudio==2.8.0 torchvision==0.23.0 --index-url ${TORCH_INDEX}
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# CTranslate2 dlopens cuBLAS/cuDNN by name; point it at the copies pip installed.
ENV LD_LIBRARY_PATH=/usr/local/lib/python3.12/site-packages/nvidia/cublas/lib:/usr/local/lib/python3.12/site-packages/nvidia/cudnn/lib \
    HF_HOME=/models/huggingface \
    TORCH_HOME=/models/torch \
    PYTHONUNBUFFERED=1

COPY app.py engine.py shaping.py ./
EXPOSE 8765
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8765/health')"
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8765", "--no-access-log"]
