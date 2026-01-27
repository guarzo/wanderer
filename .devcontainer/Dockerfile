FROM elixir:1.17-otp-27

# Install OS packages and Node.js (via nodesource),
# plus inotify-tools, yarn, and zsh
RUN apt-get update && apt-get install -y --no-install-recommends \
    sudo \
    curl \
    make \
    git \
    bash \
    zsh \
    build-essential \
    ca-certificates \
    jq \
    vim \
    net-tools \
    procps \
    netcat-openbsd \
    && curl -sL https://deb.nodesource.com/setup_18.x | bash - \
    && apt-get install -y --no-install-recommends nodejs inotify-tools \
    && npm install -g yarn \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN apt --fix-broken install

# Install Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Create non-root user with UID 1000 (matches typical host user)
ARG USERNAME=developer
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m $USERNAME -s /bin/zsh \
    && echo $USERNAME ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

# Install hex and rebar for both root and developer user
RUN mix local.hex --force && mix local.rebar --force

USER $USERNAME

# Install hex and rebar for developer user
RUN mix local.hex --force && mix local.rebar --force

# Create .zshrc for the developer user
RUN echo '# Wanderer devcontainer zsh config\n\
autoload -Uz compinit && compinit\n\
autoload -Uz colors && colors\n\
\n\
# History settings\n\
HISTFILE=~/.zsh_history\n\
HISTSIZE=10000\n\
SAVEHIST=10000\n\
setopt appendhistory\n\
setopt sharehistory\n\
setopt hist_ignore_dups\n\
\n\
# Prompt\n\
PROMPT="%F{cyan}%n@wanderer%f %F{yellow}%~%f %# "\n\
\n\
# Load dotfiles from host (if mounted)\n\
if [[ -d ~/.dotfiles ]]; then\n\
  export ZSH=$HOME/.dotfiles\n\
  export DOTFILES=$HOME/.dotfiles\n\
  typeset -U config_files\n\
  config_files=($DOTFILES/**/*.zsh)\n\
  for file in ${(M)config_files:#*/path.zsh}; do source $file 2>/dev/null; done\n\
  for file in ${${config_files:#*/path.zsh}:#*/completion.zsh}; do source $file 2>/dev/null; done\n\
  unset config_files\n\
fi\n\
\n\
# Fallback aliases if dotfiles not available\n\
alias ll="ls -la"\n\
alias la="ls -A"\n\
alias gs="git status"\n\
alias gd="git diff"\n\
\n\
# Elixir/Phoenix aliases\n\
alias mt="mix test"\n\
alias mc="mix compile"\n\
alias mf="mix format"\n\
alias ms="iex -S mix phx.server"\n\
alias deps="mix deps.get"\n\
\n\
export EDITOR=vim\n\
cd /app 2>/dev/null || true\n\
' > /home/$USERNAME/.zshrc

WORKDIR /app
