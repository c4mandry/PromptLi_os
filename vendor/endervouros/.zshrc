# --- PERFORMANCE OPTIMIZATIONS ---
DISABLE_AUTO_UPDATE="true"
DISABLE_MAGIC_FUNCTIONS="true"
ZSH_DISABLE_COMPFIX="true"

# Cache completions aggressively
autoload -Uz compinit
if [ -f ~/.zcompdump ] && [ "$(date +'%j')" = "$(date -r ~/.zcompdump +'%j')" ]; then
    compinit -C
else
    compinit
fi

# --- PATH CONFIGURATION ---
export PATH="$HOME/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

# --- OH MY ZSH SETUP ---
export ZSH="$HOME/.oh-my-zsh"

# Set ZSH_THEME to empty so it doesn't conflict with Starship
ZSH_THEME="agnoster"

# --- PLUGINS (syntax highlighting must be last) ---
plugins=(
  git
  zsh-autosuggestions
  zsh-syntax-highlighting
)

source $ZSH/oh-my-zsh.sh

# --- AUTOSUGGEST SETTINGS ---
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=#666666"
ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE="20"
ZSH_AUTOSUGGEST_USE_ASYNC=1

# --- SHELL OPTIONS ---
setopt AUTO_CD              # Type a directory name to cd into it directly
setopt AUTO_PUSHD           # Push visited dirs to stack
setopt PUSHD_IGNORE_DUPS    # Don't store duplicate dirs in stack
setopt HIST_IGNORE_ALL_DUPS # Don't record duplicate commands in history
setopt HIST_SAVE_NO_DUPS    # Don't write duplicate commands to history file
setopt HIST_REDUCE_BLANKS   # Remove superfluous blanks from history items
setopt SHARE_HISTORY        # Share history across all active zsh terminals

# History configuration
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000

# Fix Space key behavior completely
bindkey " " self-insert
bindkey -M emacs " " self-insert
bindkey -M viins " " self-insert

# --- LAZY LOAD SSH AGENT ---
function _load_ssh_agent() {
    if [ -z "$SSH_AUTH_SOCK" ]; then
        eval "$(ssh-agent -s)" > /dev/null
        ssh-add 2>/dev/null
    fi
}
autoload -U add-zsh-hook
add-zsh-hook precmd _load_ssh_agent

# --- USEFUL ALIASES ---
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."
alias ls="ls --color=auto"
alias ll="ls -l"
alias la="ls -la"
alias grep="grep --color=auto"

# Reload configuration quickly
alias reload="source ~/.zshrc"

# --- SOURCE GLOBAL ALIASES LAST ---
[ -f ~/.zsh_aliases ] && source ~/.zsh_aliases

fastfetch

# Force Agnoster theme into Black & White
prompt_segment() {
  local bg fg
  [[ -n $1 ]] && bg="%K{$1}" || bg="%k"
  [[ -n $2 ]] && fg="%F{$2}" || fg="%f"
  if [[ $CURRENT_BG != 'NONE' && $1 != $CURRENT_BG ]]; then
    echo -n " %{$bg%F{$CURRENT_BG}%}$SEGMENT_SEPARATOR%{$fg%} "
  else
    echo -n "%{$bg$fg%} "
  fi
  CURRENT_BG=$1
  [[ -n $3 ]] && echo -n "$3"
}

# Override segment colors to dark grey, mid grey, white
AGNOSTER_CONTEXT_BG="235"
AGNOSTER_CONTEXT_FG="white"
AGNOSTER_DIR_BG="238"
AGNOSTER_DIR_FG="white"
AGNOSTER_GIT_BG="242"
AGNOSTER_GIT_FG="black"

eval "$(starship init zsh)"

# --- RED STDERR: error messages print in red, normal output untouched ---
if [[ -t 2 && "$TERM" != "dumb" ]]; then
  exec 2> >(while IFS= read -r line; do printf '\033[31m%s\033[0m\n' "$line"; done)
fi
