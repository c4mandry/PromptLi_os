# Models

This directory is a convenience location for model files. By default AIDO
looks in `~/.aido/models/` (see `config/aido.yaml`); the repo layout keeps
models out of git (see `.gitignore`).

## Download the MVP model (Granite 4.0 H 1B, Q4_K_M, ~700MB, Apache-2.0)

```bash
# Into the default location:
scripts/download_model.sh

# Or into this directory:
wget -O models/granite.gguf \
  https://huggingface.co/ibm-granite/granite-4.0-h-1b-GGUF/resolve/main/granite-4.0-h-1b-Q4_K_M.gguf

# Then tell AIDO where it is:
aido --model models/granite.gguf
```

## Upgrading tiers (same codebase, just swap the model)

| Tier       | Model                     | File |
|------------|---------------------------|------|
| AIDO-FAST  | Granite 4.0 H 1B (Q4)     | `granite.gguf` |
| AIDO-PRO   | Llama 3.2 3B (Q4)         | `llama-3.2-3b-q4.gguf` |
| AIDO-ULTRA | Qwen 2.5 14B (Q4)         | `qwen2.5-14b-q4.gguf` |

Set `model.path` in `config/aido.yaml` (or pass `--model`) to switch.
