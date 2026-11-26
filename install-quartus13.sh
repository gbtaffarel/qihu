#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Distro-agnostic installer for Altera Quartus II 13.0 SP1 Web Edition (Linux)
# + `quartus` CLI wrapper (`quartus compile`, `quartus fpga`, `quartus gui`)
# ==============================================================================

ISO_URL="https://archive.org/download/quartus-web-13.0.1.232/Quartus-web-13.0.1.232.iso"
ISO_NAME="Quartus-web-13.0.1.232.iso"
DEFAULT_INSTALL_DIR="${HOME}/altera/13.0sp1"
DEFAULT_BIN_DIR="${HOME}/.local/bin"

INSTALL_DIR="${QUARTUS_INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
BIN_DIR="${QUARTUS_BIN_DIR:-$DEFAULT_BIN_DIR}"
ISO_PATH=""
CLEAN_ISO=false
ALL_DEVICES=false
SKIP_DEPS_CHECK=false
SETUP_UDEV=false

usage() {
  cat <<EOF
Uso: $0 [opções]

Opções:
  --install-dir DIR   Diretório de instalação (padrão: $DEFAULT_INSTALL_DIR)
  --bin-dir DIR       Diretório para o comando 'quartus' no PATH (padrão: $DEFAULT_BIN_DIR)
  --iso PATH          Usar um arquivo .iso já baixado em vez de baixar novamente
  --clean-iso         Remover o .iso após a instalação
  --all-devices       Instalar também MAX, Arria e Cyclone V (padrão: apenas Cyclone II/III/IV)
  --setup-udev        Configurar regra udev para USB-Blaster (usa sudo)
  --skip-deps         Pular verificação de bibliotecas 32-bit
  -h, --help          Mostrar esta ajuda
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --bin-dir)     BIN_DIR="$2"; shift 2 ;;
    --iso)         ISO_PATH="$2"; shift 2 ;;
    --clean-iso)   CLEAN_ISO=true; shift ;;
    --all-devices) ALL_DEVICES=true; shift ;;
    --setup-udev)  SETUP_UDEV=true; shift ;;
    --skip-deps)   SKIP_DEPS_CHECK=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Opção desconhecida: $1" >&2; usage; exit 1 ;;
  esac
done

log()  { printf "\033[1;34m[quartus-install]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[aviso]\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[1;31m[erro]\033[0m %s\n" "$*" >&2; }

# ------------------------------------------------------------------------------
# 1. Check 32-bit runtime dependencies (distro-agnostic hints)
# ------------------------------------------------------------------------------
check_32bit_deps() {
  if [[ "$SKIP_DEPS_CHECK" == true ]]; then
    return 0
  fi

  local missing=false
  if ! ldconfig -p 2>/dev/null | grep -q "libc.so.6.*32bit\|/lib32/\|/lib/i386-linux-gnu/\|/usr/lib32/"; then
    # Fallback check for common 32-bit dynamic linker paths
    if [[ ! -e /lib/ld-linux.so.2 && ! -e /lib32/ld-linux.so.2 ]]; then
      missing=true
    fi
  fi

  if [[ "$missing" == true ]]; then
    warn "Bibliotecas 32-bit (i386/i686) parecem estar ausentes. O Quartus II 13.0 SP1 precisa delas."
    if [[ -f /etc/os-release ]]; then
      # shellcheck disable=SC1091
      source /etc/os-release
      case "${ID:-}" in
        arch|endeavouros|manjaro|cachyos)
          echo "  Arch/derivados (habilite [multilib] em /etc/pacman.conf):"
          echo "    sudo pacman -S lib32-glibc lib32-libxext lib32-libx11 lib32-freetype2 lib32-fontconfig lib32-expat lib32-libpng12"
          ;;
        ubuntu|debian|pop|linuxmint)
          echo "  Debian/Ubuntu/derivados:"
          echo "    sudo dpkg --add-architecture i386 && sudo apt update"
          echo "    sudo apt install libc6:i386 libxext6:i386 libx11-6:i386 libfreetype6:i386 libfontconfig1:i386 libexpat1:i386"
          ;;
        fedora|rhel|centos|rocky|almalinux)
          echo "  Fedora/RHEL:"
          echo "    sudo dnf install glibc.i686 libXext.i686 libX11.i686 freetype.i686 fontconfig.i686 expat.i686"
          ;;
        opensuse*|suse)
          echo "  openSUSE:"
          echo "    sudo zypper install glibc-32bit libXext6-32bit libX11-6-32bit libfreetype6-32bit fontconfig-32bit libexpat1-32bit"
          ;;
      esac
    fi
    warn "Continuando mesmo assim (use --skip-deps para silenciar)."
  fi
}

# ------------------------------------------------------------------------------
# 2. Install Quartus II 13.0 SP1 if not already present
# ------------------------------------------------------------------------------
install_quartus() {
  if [[ -x "$INSTALL_DIR/quartus/bin/quartus_sh" ]]; then
    log "Quartus II 13.0 SP1 já encontrado em $INSTALL_DIR. Pulando download/instalação."
    return 0
  fi

  local work_dir
  work_dir="$(mktemp -d "${HOME}/.cache/quartus13-install.XXXXXX" 2>/dev/null || mktemp -d)"
  mkdir -p "$(dirname "$work_dir")" 2>/dev/null || true
  trap 'rm -rf "$work_dir"' EXIT

  if [[ -z "$ISO_PATH" ]]; then
    mkdir -p "${HOME}/Downloads"
    ISO_PATH="${HOME}/Downloads/${ISO_NAME}"
  fi

  if [[ ! -f "$ISO_PATH" ]]; then
    log "Baixando $ISO_NAME (~7.23 GB) para $ISO_PATH..."
    if command -v curl >/dev/null 2>&1; then
      curl -L -C - -o "$ISO_PATH" "$ISO_URL"
    elif command -v wget >/dev/null 2>&1; then
      wget -c -O "$ISO_PATH" "$ISO_URL"
    else
      err "Nem 'curl' nem 'wget' encontrados para baixar o ISO."
      exit 1
    fi
  else
    log "Usando ISO existente: $ISO_PATH"
  fi

  local extract_targets=(
    "components/QuartusSetupWeb-13.0.1.232.run"
    "components/cyclone_web-13.0.1.232.qdz"
  )
  if [[ "$ALL_DEVICES" == true ]]; then
    extract_targets+=(
      "components/max_web-13.0.1.232.qdz"
      "components/arria_web-13.0.1.232.qdz"
      "components/cyclonev-13.0.1.232.qdz"
    )
  fi

  log "Extraindo instalador Linux do ISO..."
  if command -v bsdtar >/dev/null 2>&1; then
    bsdtar -xf "$ISO_PATH" -C "$work_dir" "${extract_targets[@]}"
  elif command -v 7z >/dev/null 2>&1; then
    7z x -o"$work_dir" "$ISO_PATH" "${extract_targets[@]}" >/dev/null
  else
    log "bsdtar/7z não encontrados; tentando montar o ISO com sudo..."
    local mnt_dir="$work_dir/mnt"
    mkdir -p "$mnt_dir" "$work_dir/components"
    sudo mount -o loop,ro "$ISO_PATH" "$mnt_dir"
    for f in "${extract_targets[@]}"; do
      cp "$mnt_dir/$f" "$work_dir/components/"
    done
    sudo umount "$mnt_dir"
  fi

  local installer="$work_dir/components/QuartusSetupWeb-13.0.1.232.run"
  chmod +x "$installer"

  log "Instalando Quartus II 13.0 SP1 em $INSTALL_DIR (modo silencioso)..."
  mkdir -p "$INSTALL_DIR"
  (
    cd "$work_dir/components"
    ./QuartusSetupWeb-13.0.1.232.run --mode unattended --unattendedmodeui none --installdir "$INSTALL_DIR"
  )

  if [[ "$CLEAN_ISO" == true && -f "$ISO_PATH" ]]; then
    log "Removendo ISO para liberar espaço: $ISO_PATH"
    rm -f "$ISO_PATH"
  fi
}

# ------------------------------------------------------------------------------
# 3. Install `quartus` CLI wrapper into BIN_DIR
# ------------------------------------------------------------------------------
install_cli_wrapper() {
  mkdir -p "$BIN_DIR"
  local target="$BIN_DIR/quartus"

  log "Instalando comando 'quartus' em $target..."
  cat > "$target" <<EOF
#!/usr/bin/env bash
set -euo pipefail

QUARTUS_ROOT="\${QUARTUS_ROOT:-$INSTALL_DIR/quartus}"
QUARTUS_BIN="\$QUARTUS_ROOT/bin"
DEFAULT_FAMILY="\${QUARTUS_FAMILY:-Cyclone III}"
DEFAULT_DEVICE="\${QUARTUS_DEVICE:-EP3C16F484C6}"

usage() {
  cat <<'USAGE'
Uso: quartus <comando> [argumentos]

Comandos:
  compile <toplevel> [arquivos...]   Compila o projeto (gera .qpf/.qsf se não existir)
  compile                            Compila o .qpf existente no diretório atual
  fpga [arquivo.sof]                 Grava o bitstream (.sof) na FPGA via USB-Blaster
  jtag                               Verifica dispositivos JTAG conectados (jtagconfig)
  gui [arquivo.qpf]                  Abre a interface gráfica do Quartus II 13.0 SP1
  sh [args...]                       Repassa diretamente para quartus_sh
  pgm [args...]                      Repassa diretamente para quartus_pgm
  help                               Mostra esta ajuda

Variáveis de ambiente opcionais:
  QUARTUS_FAMILY   Família alvo ao criar projeto (padrão: Cyclone III)
  QUARTUS_DEVICE   Device alvo ao criar projeto  (padrão: EP3C16F484C6)
  QUARTUS_ROOT     Caminho do diretório quartus/ (padrão: $INSTALL_DIR/quartus)
USAGE
}

ensure_quartus() {
  if [[ ! -x "\$QUARTUS_BIN/quartus_sh" ]]; then
    echo "Erro: Quartus II 13.0 SP1 não encontrado em \$QUARTUS_ROOT" >&2
    exit 1
  fi
}

cmd_compile() {
  ensure_quartus
  if [[ \$# -eq 0 ]]; then
    local qpf
    qpf=\$(ls -1 *.qpf 2>/dev/null | head -n 1 || true)
    if [[ -z "\$qpf" ]]; then
      echo "Erro: nenhum .qpf encontrado e nenhum <toplevel> informado." >&2
      echo "Uso: quartus compile <toplevel> <arquivo1.v> [arquivo2.v ...]" >&2
      exit 1
    fi
    local proj="\${qpf%.qpf}"
    echo "[quartus] Compilando projeto existente: \$proj"
    "\$QUARTUS_BIN/quartus_sh" --flow compile "\$proj"
    return
  fi

  local toplevel="\$1"
  shift
  local deps=("\$@")
  local proj="\$toplevel"

  if [[ ! -f "\$proj.qpf" || ! -f "\$proj.qsf" ]]; then
    echo "[quartus] Criando projeto '\$proj' (\$DEFAULT_FAMILY / \$DEFAULT_DEVICE)..."
    cat > "\$proj.qpf" <<QPF
QUARTUS_VERSION = "13.0"
PROJECT_REVISION = "\$proj"
QPF

    cat > "\$proj.qsf" <<QSF
set_global_assignment -name FAMILY "\$DEFAULT_FAMILY"
set_global_assignment -name DEVICE \$DEFAULT_DEVICE
set_global_assignment -name TOP_LEVEL_ENTITY \$toplevel
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
QSF

    if [[ \${#deps[@]} -eq 0 ]]; then
      if [[ -f "\$toplevel.v" ]]; then
        deps=("\$toplevel.v")
      elif [[ -f "\$toplevel.sv" ]]; then
        deps=("\$toplevel.sv")
      elif [[ -f "\$toplevel.vhd" ]]; then
        deps=("\$toplevel.vhd")
      fi
    fi

    for src in "\${deps[@]}"; do
      case "\$src" in
        *.vhd|*.vhdl) echo "set_global_assignment -name VHDL_FILE \$src" >> "\$proj.qsf" ;;
        *.sv)         echo "set_global_assignment -name SYSTEMVERILOG_FILE \$src" >> "\$proj.qsf" ;;
        *.v)          echo "set_global_assignment -name VERILOG_FILE \$src" >> "\$proj.qsf" ;;
        *)            echo "set_global_assignment -name SOURCE_FILE \$src" >> "\$proj.qsf" ;;
      esac
    done
  fi

  echo "[quartus] Compilando \$proj..."
  "\$QUARTUS_BIN/quartus_sh" --flow compile "\$proj"
  echo "[quartus] Concluído! Bitstream em output_files/\$proj.sof"
}

cmd_fpga() {
  ensure_quartus
  local sof="\${1:-}"

  if [[ -z "\$sof" ]]; then
    sof=\$(ls -t output_files/*.sof *.sof 2>/dev/null | head -n 1 || true)
    if [[ -z "\$sof" ]]; then
      echo "Erro: nenhum arquivo .sof encontrado em output_files/ ou no diretório atual." >&2
      echo "Compile primeiro com 'quartus compile ...' ou informe o caminho: quartus fpga caminho.sof" >&2
      exit 1
    fi
  fi

  if [[ ! -f "\$sof" ]]; then
    echo "Erro: arquivo não encontrado: \$sof" >&2
    exit 1
  fi

  if ! "\$QUARTUS_BIN/jtagconfig" 2>/dev/null | grep -q "USB-Blaster\|Blaster"; then
    echo "Erro: nenhum gravador USB-Blaster detectado pelo jtagconfig." >&2
    "\$QUARTUS_BIN/jtagconfig" || true
    exit 1
  fi

  echo "[quartus] Gravando \$sof na FPGA..."
  "\$QUARTUS_BIN/quartus_pgm" -m jtag -o "p;\$sof"
}

case "\${1:-gui}" in
  compile) shift; cmd_compile "\$@" ;;
  fpga)    shift; cmd_fpga "\$@" ;;
  jtag)    ensure_quartus; shift; "\$QUARTUS_BIN/jtagconfig" "\$@" ;;
  gui)     ensure_quartus; shift; nohup "\$QUARTUS_BIN/quartus" "\$@" >/dev/null 2>&1 & ;;
  sh)      ensure_quartus; shift; "\$QUARTUS_BIN/quartus_sh" "\$@" ;;
  pgm)     ensure_quartus; shift; "\$QUARTUS_BIN/quartus_pgm" "\$@" ;;
  -h|--help|help) usage ;;
  *)       ensure_quartus; nohup "\$QUARTUS_BIN/quartus" "\$@" >/dev/null 2>&1 & ;;
esac
EOF
  chmod +x "$target"
}

# ------------------------------------------------------------------------------
# 4. Desktop entry + PATH + optional udev rules
# ------------------------------------------------------------------------------
install_desktop_entry() {
  local apps_dir="${HOME}/.local/share/applications"
  mkdir -p "$apps_dir"
  cat > "$apps_dir/quartus-13.0sp1.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=Quartus II 13.0 SP1
Comment=Altera Quartus II 13.0 SP1 Web Edition (Cyclone II/III/IV)
Exec=$INSTALL_DIR/quartus/bin/quartus %F
Icon=$INSTALL_DIR/quartus/adm/quartusii.png
Terminal=false
Type=Application
Categories=Development;
EOF
  chmod 644 "$apps_dir/quartus-13.0sp1.desktop"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$apps_dir" || true
}

setup_udev_rules() {
  if [[ "$SETUP_UDEV" != true ]]; then
    return 0
  fi
  log "Configurando regra udev para Altera USB-Blaster (/etc/udev/rules.d/51-usbblaster.rules)..."
  sudo tee /etc/udev/rules.d/51-usbblaster.rules >/dev/null <<'UDEV'
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="09fb", ATTR{idProduct}=="6001", MODE="0666"
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="09fb", ATTR{idProduct}=="6002", MODE="0666"
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="09fb", ATTR{idProduct}=="6003", MODE="0666"
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="09fb", ATTR{idProduct}=="6010", MODE="0666"
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="09fb", ATTR{idProduct}=="6810", MODE="0666"
UDEV
  sudo udevadm control --reload-rules
  sudo udevadm trigger
}

check_path() {
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
      warn "$BIN_DIR não está no seu \$PATH atual."
      echo "  Adicione esta linha ao seu ~/.bashrc ou ~/.zshrc:"
      echo "    export PATH=\"$BIN_DIR:\$PATH\""
      ;;
  esac
}

main() {
  check_32bit_deps
  install_quartus
  install_cli_wrapper
  install_desktop_entry
  setup_udev_rules
  check_path
  log "Tudo pronto! Teste com: quartus help"
}

main
