#!/bin/sh
set -eu

model_name="sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20"
model_archive="${model_name}.tar.bz2"
model_url="https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/${model_archive}"
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
models_dir="${repo_root}/models"
model_dir="${models_dir}/${model_name}"

mkdir -p "${models_dir}"
if [ ! -d "${model_dir}" ]; then
  curl --fail --location "${model_url}" --output "${models_dir}/${model_archive}"
  tar -xjf "${models_dir}/${model_archive}" -C "${models_dir}"
  rm "${models_dir}/${model_archive}"
fi

uv run sherpa-onnx-cli text2token \
  --tokens "${model_dir}/tokens.txt" \
  --tokens-type phone+ppinyin \
  --lexicon "${model_dir}/en.phone" \
  "${models_dir}/keywords.raw.txt" \
  "${models_dir}/hey-lobby.txt"

echo "Model ready: ${model_dir}"
echo "Keyword tokens: ${models_dir}/hey-lobby.txt"
