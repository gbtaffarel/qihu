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
WITH_RTL=false

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
  --with-rtl          Instalar dependências de visualização RTL (yosys, netlistsvg e DigitalJS)
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
    --with-rtl)    WITH_RTL=true; shift ;;
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
    "components/ModelSimSetup-13.0.1.232.run"
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
    if [[ -f ModelSimSetup-13.0.1.232.run ]]; then
      chmod +x ModelSimSetup-13.0.1.232.run
      log "Instalando ModelSim-Altera 13.0 SP1 (simulador de waveform)..."
      ./ModelSimSetup-13.0.1.232.run --mode unattended --unattendedmodeui none --installdir "$INSTALL_DIR"
    fi
  )

  if [[ -f "$INSTALL_DIR/modelsim_ase/vco" ]]; then
    chmod u+w "$INSTALL_DIR/modelsim_ase/vco"
    sed -i 's/vco="linux_rh60"/vco="linux"/' "$INSTALL_DIR/modelsim_ase/vco"
  fi

  local qsim_tcl="$INSTALL_DIR/quartus/common/tcl/apps/qsim/qsim_script_modified.tcl"
  if [[ -f "$qsim_tcl" ]]; then
    chmod u+w "$qsim_tcl"
    sed -i 's|\.\.\\\\\.\.\\\\modelsim_ae\\\\win32aloem\\\\|../../modelsim_ae/bin/|g; s|\.\.\\\\\.\.\\\\modelsim_ase\\\\win32aloem\\\\|../../modelsim_ase/bin/|g' "$qsim_tcl"
    sed -i -E 's|^([[:space:]]*)(file attributes .* -readonly [01])|\1catch { \2 }|' "$qsim_tcl"
  fi

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
  cat > "$target.tmp" <<EOF
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
  compile [--board de0] <toplevel> [arquivos...]
                                     Compila o projeto (gera .qpf/.qsf se não existir)
  compile                            Compila o .qpf existente no diretório atual
  rtl [--digitaljs|--svg|--quartus] <toplevel.v> [arquivos...]
                                     Visualiza o esquemático RTL (padrão: auto)
  sim [--wave] [--modelsim] <tb.v> [arquivos...]
                                     Simula testbench (iverilog/vvp/gtkwave ou ModelSim)
  fpga [--recompile] [--permanent] [arquivo.sof|pof]
                                     Grava o bitstream na FPGA (.sof JTAG ou .pof AS)
  report                             Exibe resumo de recursos e timing da compilação
  pins [--apply arquivo.qsf]         Lista pinagem da placa DE0 ou aplica em um .qsf
  watch <comando> [args...]          Reexecuta um comando ao salvar arquivos .v/.sv/.vhd
  doctor                             Verifica dependências, patches, udev e JTAG
  install rtl                        Instala dependências RTL (yosys, netlistsvg e DigitalJS)
  clean                              Remove arquivos gerados pela compilação e pelo RTL
  jtag                               Verifica dispositivos JTAG conectados (jtagconfig)
  gui [arquivo.qpf]                  Abre a interface gráfica do Quartus II 13.0 SP1
  update                             Atualiza o utilitário 'quartus' a partir do GitHub
  uninstall [-y|--yes]               Remove o Quartus II 13.0 SP1, o comando e o atalho .desktop
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

de0_pin_assignments() {
  cat <<'DE0PINS'
# Terasic DE0 (EP3C16F484C6) Pin Assignments
set_location_assignment PIN_G21 -to CLOCK_50
set_location_assignment PIN_H2 -to BUTTON[0]
set_location_assignment PIN_G3 -to BUTTON[1]
set_location_assignment PIN_F1 -to BUTTON[2]
set_location_assignment PIN_J6 -to SW[0]
set_location_assignment PIN_H5 -to SW[1]
set_location_assignment PIN_H6 -to SW[2]
set_location_assignment PIN_G4 -to SW[3]
set_location_assignment PIN_G5 -to SW[4]
set_location_assignment PIN_J7 -to SW[5]
set_location_assignment PIN_H7 -to SW[6]
set_location_assignment PIN_E3 -to SW[7]
set_location_assignment PIN_E4 -to SW[8]
set_location_assignment PIN_D2 -to SW[9]
set_location_assignment PIN_J1 -to LEDG[0]
set_location_assignment PIN_J2 -to LEDG[1]
set_location_assignment PIN_J3 -to LEDG[2]
set_location_assignment PIN_H1 -to LEDG[3]
set_location_assignment PIN_F2 -to LEDG[4]
set_location_assignment PIN_E1 -to LEDG[5]
set_location_assignment PIN_C1 -to LEDG[6]
set_location_assignment PIN_C2 -to LEDG[7]
set_location_assignment PIN_B2 -to LEDG[8]
set_location_assignment PIN_B1 -to LEDG[9]
DE0PINS
}

cmd_compile() {
  local board=""
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      -h|--help)
        cat <<'HELP'
Uso:
  quartus compile                            Compila o .qpf existente no diretório atual
  quartus compile [--board de0] <toplevel> [arquivos...]
                                             Cria .qpf/.qsf (se não existir) e compila

Descrição:
  Executa síntese, place & route e geração do bitstream (.sof) em output_files/.
  Sem argumentos, procura o arquivo .qpf no diretório atual.
  Com <toplevel>, cria um projeto novo usando QUARTUS_FAMILY (padrão: Cyclone III)
  e QUARTUS_DEVICE (padrão: EP3C16F484C6) caso ainda não exista.

Opções:
  --board de0   Inclui os pinos padrão da placa Terasic DE0 ao criar o .qsf
  -h, --help    Mostra esta ajuda

Exemplos:
  quartus compile
  quartus compile --board de0 top top.v
  quartus compile booth_top booth_top.v booth_control.v booth_datapath.v
HELP
        return 0
        ;;
      --board) board="\${2:-}"; shift 2 ;;
      *) break ;;
    esac
  done

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

  local top_arg="\$1"
  shift
  local toplevel="\$(basename "\$top_arg")"
  toplevel="\${toplevel%.*}"
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
      if [[ -f "\$top_arg" ]]; then
        deps=("\$top_arg")
      elif [[ -f "\$toplevel.v" ]]; then
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

    if [[ "\$board" == "de0" ]]; then
      de0_pin_assignments >> "\$proj.qsf"
    fi
  elif [[ "\$board" == "de0" ]]; then
    sed -i -E 's|^set_global_assignment -name FAMILY .*|set_global_assignment -name FAMILY "Cyclone III"|; s|^set_global_assignment -name DEVICE .*|set_global_assignment -name DEVICE EP3C16F484C6|' "\$proj.qsf"
    if ! grep -q "Terasic DE0" "\$proj.qsf" 2>/dev/null; then
      echo "" >> "\$proj.qsf"
      de0_pin_assignments >> "\$proj.qsf"
    fi
  fi

  echo "[quartus] Compilando \$proj..."
  "\$QUARTUS_BIN/quartus_sh" --flow compile "\$proj"
  echo "[quartus] Concluído! Bitstream em output_files/\$proj.sof"
}

cmd_fpga() {
  local recompile=false
  local permanent=false
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      -h|--help)
        cat <<'HELP'
Uso: quartus fpga [--recompile|-r] [--permanent|-p] [arquivo.sof|pof]

Descrição:
  Grava o bitstream na FPGA conectada via USB-Blaster.
  Por padrão usa modo JTAG (.sof, volátil). Com --permanent usa modo Active
  Serial (.pof, memória flash não-volátil da placa).

Opções:
  -r, --recompile   Recompila o projeto .qpf do diretório atual antes de gravar
  -p, --permanent   Grava arquivo .pof em modo Active Serial (persiste após desligar)
  -h, --help        Mostra esta ajuda

Exemplos:
  quartus fpga
  quartus fpga --recompile
  quartus fpga --permanent output_files/projeto.pof
HELP
        return 0
        ;;
      --recompile|-r) recompile=true; shift ;;
      --permanent|-p) permanent=true; shift ;;
      *) break ;;
    esac
  done

  ensure_quartus

  if [[ "\$recompile" == true ]]; then
    cmd_compile
  fi

  local ext="sof"
  local mode="jtag"
  if [[ "\$permanent" == true ]]; then
    ext="pof"
    mode="as"
  fi

  local bitfile="\${1:-}"

  if [[ -z "\$bitfile" ]]; then
    bitfile=\$(ls -t output_files/*.\$ext *.\$ext 2>/dev/null | head -n 1 || true)
    if [[ -z "\$bitfile" ]]; then
      echo "Erro: nenhum arquivo .\$ext encontrado em output_files/ ou no diretório atual." >&2
      if [[ "\$permanent" == true ]]; then
        echo "Gere o .pof (ou informe o caminho: quartus fpga --permanent arquivo.pof)." >&2
      else
        echo "Compile primeiro com 'quartus compile ...' ou informe o caminho: quartus fpga caminho.sof" >&2
      fi
      exit 1
    fi
  fi

  if [[ ! -f "\$bitfile" ]]; then
    echo "Erro: arquivo não encontrado: \$bitfile" >&2
    exit 1
  fi

  if ! "\$QUARTUS_BIN/jtagconfig" 2>/dev/null | grep -q "USB-Blaster\|Blaster"; then
    echo "Erro: nenhum gravador USB-Blaster detectado pelo jtagconfig." >&2
    "\$QUARTUS_BIN/jtagconfig" || true
    exit 1
  fi

  echo "[quartus] Gravando \$bitfile na FPGA (modo: \$mode)..."
  "\$QUARTUS_BIN/quartus_pgm" -m "\$mode" -o "p;\$bitfile"
}

cmd_rtl() {
  local mode="auto"
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      -h|--help)
        cat <<'HELP'
Uso: quartus rtl [--digitaljs|--svg|--quartus] <arquivo_toplevel.v> [dependencias...]

Descrição:
  Gera e abre a visualização do esquemático RTL (netlist) do circuito.
  Se apenas o arquivo top-level for informado, coleta automaticamente os demais
  arquivos .v/.sv do diretório (ignorando testbenches *tb*.v / *testbench*.v).

Opções:
  --digitaljs   Gera HTML interativo com DigitalJS e abre no navegador
  --svg         Gera SVG estático com Yosys + netlistsvg
  --quartus     Sintetiza com Quartus e abre a GUI para usar o RTL Viewer
  --auto        Escolhe automaticamente (DigitalJS -> SVG -> Quartus) [padrão]
  -h, --help    Mostra esta ajuda

Exemplos:
  quartus rtl booth_top.v
  quartus rtl --svg booth_top.v
  quartus rtl --digitaljs booth_top.v booth_control.v booth_datapath.v
HELP
        return 0
        ;;
      --digitaljs) mode="digitaljs"; shift ;;
      --svg|--yosys) mode="svg"; shift ;;
      --quartus|--viewer) mode="quartus"; shift ;;
      --auto) mode="auto"; shift ;;
      *) break ;;
    esac
  done

  if [[ \$# -eq 0 ]]; then
    echo "Uso: quartus rtl [--digitaljs|--svg|--quartus] <arquivo_toplevel.v> [dependencias...]" >&2
    exit 1
  fi

  local top_arg="\$1"
  shift
  local top_name="\$(basename "\$top_arg")"
  top_name="\${top_name%.*}"

  local srcs=()
  if [[ \$# -gt 0 ]]; then
    if [[ -f "\$top_arg" ]]; then
      srcs=("\$top_arg" "\$@")
    else
      srcs=("\$@")
    fi
  else
    # 1) Se existir <top_name>.qsf, usa exatamente os arquivos declarados no projeto
    if [[ -f "\$top_name.qsf" ]]; then
      while IFS= read -r qsf_file; do
        [[ -n "\$qsf_file" && -f "\$qsf_file" ]] && srcs+=("\$qsf_file")
      done < <(grep -E 'set_global_assignment[[:space:]]+-name[[:space:]]+(SYSTEM)?VERILOG_FILE[[:space:]]+' "\$top_name.qsf" | sed -E 's/.*VERILOG_FILE[[:space:]]+//; s/[[:space:]]*$//; s/^"//; s/"$//' | tr -d '\r')
    fi

    # 2) Se não há .qsf, testa se o arquivo top-level é autocontido (evita colisão com outros .v da pasta)
    local top_file=""
    if [[ -f "\$top_arg" ]]; then
      top_file="\$top_arg"
    elif [[ -f "\$top_name.v" ]]; then
      top_file="\$top_name.v"
    elif [[ -f "\$top_name.sv" ]]; then
      top_file="\$top_name.sv"
    fi

    if [[ \${#srcs[@]} -eq 0 && -n "\$top_file" ]] && command -v yosys >/dev/null 2>&1; then
      if yosys -q -p "read_verilog \$top_file; hierarchy -check -top \$top_name" >/dev/null 2>&1; then
        srcs=("\$top_file")
      fi
    fi

    # 3) Fallback: coleta os demais .v/.sv do diretório (ignorando testbenches)
    if [[ \${#srcs[@]} -eq 0 ]]; then
      shopt -s nullglob
      for f in *.v *.sv; do
        case "\$f" in
          *tb*.v|*testbench*.v|*tb*.sv|*testbench*.sv) continue ;;
          *) srcs+=("\$f") ;;
        esac
      done
      shopt -u nullglob
      if [[ \${#srcs[@]} -eq 0 && -n "\$top_file" ]]; then
        srcs=("\$top_file")
      fi
    fi
  fi

  if [[ \${#srcs[@]} -eq 0 ]]; then
    echo "Erro: nenhum arquivo HDL encontrado para gerar o RTL." >&2
    exit 1
  fi

  mkdir -p build
  local digitaljs_render="\${DIGITALJS_RENDER:-\$HOME/.local/share/digitaljs/render.js}"
  local netlistsvg_bin=""
  if command -v netlistsvg >/dev/null 2>&1; then
    netlistsvg_bin="netlistsvg"
  elif [[ -x "\$HOME/.local/share/digitaljs/node_modules/.bin/netlistsvg" ]]; then
    netlistsvg_bin="\$HOME/.local/share/digitaljs/node_modules/.bin/netlistsvg"
  fi

  if [[ "\$mode" == "auto" ]]; then
    if [[ -f "\$digitaljs_render" ]] && command -v node >/dev/null 2>&1 && command -v yosys >/dev/null 2>&1; then
      mode="digitaljs"
    elif command -v yosys >/dev/null 2>&1 && [[ -n "\$netlistsvg_bin" ]]; then
      mode="svg"
    else
      mode="quartus"
    fi
  fi

  case "\$mode" in
    digitaljs)
      if [[ ! -f "\$digitaljs_render" ]] || ! command -v node >/dev/null 2>&1 || ! command -v yosys >/dev/null 2>&1; then
        echo "Erro: DigitalJS (\$digitaljs_render), node ou yosys não encontrado." >&2
        echo "Instale com: quartus install rtl" >&2
        exit 1
      fi
      local html_out="build/\${top_name}_rtl.html"
      echo "[quartus] Gerando RTL interativo (DigitalJS) para '\$top_name'..."
      node "\$digitaljs_render" --top "\$top_name" -o "\$html_out" "\${srcs[@]}"
      echo "[quartus] Abrindo \$html_out..."
      nohup xdg-open "\$html_out" >/dev/null 2>&1 &
      ;;
    svg)
      if ! command -v yosys >/dev/null 2>&1 || [[ -z "\$netlistsvg_bin" ]]; then
        echo "Erro: yosys ou netlistsvg não encontrados." >&2
        echo "Instale com: quartus install rtl" >&2
        exit 1
      fi
      local json_out="build/\${top_name}_rtl.json"
      local svg_out="build/\${top_name}_rtl.svg"
      echo "[quartus] Gerando RTL SVG (Yosys + netlistsvg) para '\$top_name'..."
      yosys -q -p "read_verilog \${srcs[*]}; prep -top \$top_name; write_json \$json_out"
      "\$netlistsvg_bin" "\$json_out" -o "\$svg_out"
      echo "[quartus] Abrindo \$svg_out..."
      nohup xdg-open "\$svg_out" >/dev/null 2>&1 &
      ;;
    quartus)
      ensure_quartus
      echo "[quartus] Sintetizando '\$top_name' com Quartus para abrir no RTL Viewer..."
      if [[ ! -f "\$top_name.qpf" || ! -f "\$top_name.qsf" ]]; then
        cmd_compile "\$top_name" "\${srcs[@]}" >/dev/null
      else
        "\$QUARTUS_BIN/quartus_map" --read_settings_files=on --write_settings_files=off "\$top_name" -c "\$top_name"
      fi
      echo "[quartus] Abrindo Quartus GUI (acesse Tools -> Netlist Viewers -> RTL Viewer)..."
      nohup "\$QUARTUS_BIN/quartus" "\$top_name.qpf" >/dev/null 2>&1 &
      ;;
  esac
}

cmd_update() {
  if [[ "\${1:-}" == "-h" || "\${1:-}" == "--help" ]]; then
    cat <<'HELP'
Uso: quartus update [opções_do_instalador]

Descrição:
  Baixa a versão mais recente do script no GitHub e atualiza o comando 'quartus'
  e o atalho .desktop sem baixar ou reinstalar o Quartus II 13.0 SP1 novamente.

Opções:
  --setup-udev   Configura a regra udev do USB-Blaster (usa sudo)
  --all-devices  Instala suporte adicional (se ainda não instalado)
  -h, --help     Mostra esta ajuda
HELP
    return 0
  fi

  local url="\${QUARTUS_UPDATE_URL:-https://raw.githubusercontent.com/gbtaffarel/quartus-installer/main/install-quartus13.sh}"
  local tmp_script
  tmp_script="\$(mktemp)"
  trap 'rm -f "\$tmp_script"' RETURN

  echo "[quartus] Baixando atualização de \$url..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "\$url" -o "\$tmp_script"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "\$tmp_script" "\$url"
  else
    echo "Erro: nem 'curl' nem 'wget' encontrados." >&2
    exit 1
  fi

  chmod +x "\$tmp_script"
  QUARTUS_INSTALL_DIR="$INSTALL_DIR" QUARTUS_BIN_DIR="$BIN_DIR" bash "\$tmp_script" "\$@"
}

cmd_uninstall() {
  if [[ "\${1:-}" == "-h" || "\${1:-}" == "--help" ]]; then
    cat <<'HELP'
Uso: quartus uninstall [-y|--yes]

Descrição:
  Remove o Quartus II 13.0 SP1, o comando 'quartus' e o atalho .desktop.
  Também pergunta se deseja remover dependências opcionais (DigitalJS/netlistsvg,
  regra udev do USB-Blaster e pacotes de sistema yosys/nodejs/npm).

Opções:
  -y, --yes   Não pede confirmação para Quartus, DigitalJS e regra udev
  -h, --help  Mostra esta ajuda
HELP
    return 0
  fi

  local auto_yes=false
  if [[ "\${1:-}" == "-y" || "\${1:-}" == "--yes" ]]; then
    auto_yes=true
  fi

  local desktop_file="\${HOME}/.local/share/applications/quartus-13.0sp1.desktop"
  local self_bin="$BIN_DIR/quartus"

  echo "Isso removerá:"
  echo "  - $INSTALL_DIR"
  echo "  - \$self_bin"
  echo "  - \$desktop_file"

  if [[ "\$auto_yes" != true ]]; then
    read -r -p "Tem certeza que deseja desinstalar? [s/N] " resp
    case "\$resp" in
      s|S|sim|SIM|y|Y|yes|YES) ;;
      *) echo "Cancelado."; exit 0 ;;
    esac
  fi

  rm -rf "$INSTALL_DIR"
  rm -f "\$desktop_file"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "\${HOME}/.local/share/applications" || true
  rm -f "\$self_bin"

  local djs_dir="\${HOME}/.local/share/digitaljs"
  if [[ -d "\$djs_dir" ]]; then
    if [[ "\$auto_yes" == true ]]; then
      rm -rf "\$djs_dir"
    else
      read -r -p "Deseja remover também o DigitalJS/netlistsvg local (\$djs_dir)? [s/N] " resp_djs
      case "\$resp_djs" in
        s|S|sim|SIM|y|Y|yes|YES) rm -rf "\$djs_dir" ;;
      esac
    fi
  fi

  if [[ -f /etc/udev/rules.d/51-usbblaster.rules ]]; then
    if [[ "\$auto_yes" == true ]]; then
      sudo rm -f /etc/udev/rules.d/51-usbblaster.rules && sudo udevadm control --reload-rules || true
    else
      read -r -p "Deseja remover a regra udev do USB-Blaster (/etc/udev/rules.d/51-usbblaster.rules, usa sudo)? [s/N] " resp_udev
      case "\$resp_udev" in
        s|S|sim|SIM|y|Y|yes|YES)
          sudo rm -f /etc/udev/rules.d/51-usbblaster.rules && sudo udevadm control --reload-rules || true
          ;;
      esac
    fi
  fi

  if command -v yosys >/dev/null 2>&1 || command -v npm >/dev/null 2>&1; then
    local remove_sys=false
    if [[ "\$auto_yes" != true ]]; then
      read -r -p "Deseja remover também os pacotes do sistema (yosys, nodejs, npm)? [s/N] " resp_sys
      case "\$resp_sys" in
        s|S|sim|SIM|y|Y|yes|YES) remove_sys=true ;;
      esac
    fi
    if [[ "\$remove_sys" == true ]]; then
      if command -v pacman >/dev/null 2>&1; then
        sudo pacman -Rs yosys nodejs npm || true
      elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get remove -y yosys nodejs npm || true
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf remove -y yosys nodejs npm || true
      elif command -v zypper >/dev/null 2>&1; then
        sudo zypper remove -y yosys nodejs npm || true
      fi
    fi
  fi

  echo "[quartus] Desinstalação concluída."
}

cmd_install() {
  case "\${1:-}" in
    -h|--help)
      cat <<'HELP'
Uso: quartus install rtl

Descrição:
  Instala as dependências de visualização RTL: yosys, nodejs, npm (via
  gerenciador de pacotes da distro com sudo) e digitaljs, yosys2digitaljs e
  netlistsvg localmente em ~/.local/share/digitaljs/.
HELP
      return 0
      ;;
    rtl)
      if [[ "\${2:-}" == "-h" || "\${2:-}" == "--help" ]]; then
        cmd_install --help
        return 0
      fi
      cmd_update --with-rtl
      ;;
    *) echo "Uso: quartus install rtl" >&2; exit 1 ;;
  esac
}

cmd_clean() {
  if [[ "\${1:-}" == "-h" || "\${1:-}" == "--help" ]]; then
    cat <<'HELP'
Uso: quartus clean

Descrição:
  Remove os diretórios e arquivos gerados pela compilação do Quartus e pelo
  'quartus rtl' no diretório atual (db/, incremental_db/, output_files/,
  simulation/, greybox_tmp/, build/, *_assignment_defaults.qdf, *.rpt, *.sof, etc.).
  Os arquivos de código (.v/.sv/.vhd) e do projeto (.qpf/.qsf) são preservados.
HELP
    return 0
  fi

  echo "[quartus] Limpando arquivos de compilação no diretório atual..."
  rm -rf db incremental_db output_files simulation greybox_tmp build
  shopt -s nullglob
  local artifacts=(
    *_assignment_defaults.qdf
    *.rpt *.summary *.done *.pin *.jdi *.smsg *.sld *.qws *.bak *.sof *.pof
  )
  if [[ \${#artifacts[@]} -gt 0 ]]; then
    rm -f "\${artifacts[@]}"
  fi
  shopt -u nullglob
  echo "[quartus] Limpeza concluída."
}

cmd_sim() {
  local open_wave=false
  local use_modelsim=false
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      -h|--help)
        cat <<'HELP'
Uso: quartus sim [--wave|-w] [--modelsim] <testbench.v> [arquivos...]

Descrição:
  Compila e executa um testbench Verilog. Por padrão usa Icarus Verilog
  (iverilog + vvp). Se apenas o testbench for informado, inclui automaticamente
  os demais arquivos .v da pasta (ignorando outros *tb*.v / *testbench*.v).

Opções:
  -w, --wave    Abre o arquivo .vcd gerado no GTKWave após a simulação
  --modelsim    Usa o ModelSim-Altera (vlib/vlog/vsim) em vez do iverilog
  -h, --help    Mostra esta ajuda

Exemplos:
  quartus sim tb_booth.v
  quartus sim --wave tb_booth.v booth_top.v booth_control.v
  quartus sim --modelsim tb_booth.v
HELP
        return 0
        ;;
      -w|--wave)  open_wave=true; shift ;;
      --modelsim) use_modelsim=true; shift ;;
      *) break ;;
    esac
  done

  if [[ \$# -eq 0 ]]; then
    echo "Uso: quartus sim [--wave] [--modelsim] <testbench.v> [arquivos...]" >&2
    exit 1
  fi

  local tb_file="\$1"
  shift
  if [[ ! -f "\$tb_file" ]]; then
    echo "Erro: testbench não encontrado: \$tb_file" >&2
    exit 1
  fi

  local tb_mod="\$(basename "\$tb_file")"
  tb_mod="\${tb_mod%.*}"

  local srcs=("\$tb_file")
  if [[ \$# -gt 0 ]]; then
    srcs+=("\$@")
  else
    shopt -s nullglob
    for f in *.v; do
      [[ "\$f" == "\$tb_file" ]] && continue
      case "\$f" in
        *tb*.v|*testbench*.v) continue ;;
        *) srcs+=("\$f") ;;
      esac
    done
    shopt -u nullglob
  fi

  mkdir -p build
  if [[ "\$use_modelsim" == true ]]; then
    local msim_bin="\$(dirname "\$QUARTUS_ROOT")/modelsim_ase/bin"
    if [[ ! -x "\$msim_bin/vsim" ]]; then
      echo "Erro: ModelSim-Altera não encontrado em \$msim_bin" >&2
      exit 1
    fi
    echo "[quartus] Simulando '\$tb_mod' com ModelSim-Altera..."
    "\$msim_bin/vlib" build/work >/dev/null 2>&1 || true
    "\$msim_bin/vlog" -work build/work "\${srcs[@]}"
    "\$msim_bin/vsim" -c -lib build/work "\$tb_mod" -do "run -all; quit -f"
  else
    if ! command -v iverilog >/dev/null 2>&1 || ! command -v vvp >/dev/null 2>&1; then
      echo "Erro: 'iverilog' e 'vvp' são necessários para simulação padrão." >&2
      exit 1
    fi
    echo "[quartus] Compilando e simulando '\$tb_mod' com iverilog..."
    iverilog -Wall -o build/sim.vvp "\${srcs[@]}"
    vvp build/sim.vvp
  fi

  if [[ "\$open_wave" == true ]]; then
    local vcd_file
    vcd_file=\$(ls -t *.vcd build/*.vcd 2>/dev/null | head -n 1 || true)
    if [[ -z "\$vcd_file" ]]; then
      echo "Aviso: nenhum arquivo .vcd encontrado. Verifique \$dumpfile no testbench." >&2
      return 0
    fi
    if ! command -v gtkwave >/dev/null 2>&1; then
      echo "Erro: 'gtkwave' não encontrado no PATH." >&2
      exit 1
    fi
    echo "[quartus] Abrindo \$vcd_file no GTKWave..."
    nohup gtkwave "\$vcd_file" >/dev/null 2>&1 &
  fi
}

cmd_report() {
  if [[ "\${1:-}" == "-h" || "\${1:-}" == "--help" ]]; then
    cat <<'HELP'
Uso: quartus report [projeto]

Descrição:
  Exibe um resumo limpo no terminal com uso de lógica (LEs, registradores,
  pinos, memória), slack de timing (Setup/Hold) e contagem de erros/avisos
  a partir dos relatórios em output_files/.
HELP
    return 0
  fi

  local proj="\${1:-}"
  local fit_sum=""
  local map_sum=""
  local sta_sum=""

  if [[ -n "\$proj" ]]; then
    fit_sum="output_files/\${proj}.fit.summary"
    map_sum="output_files/\${proj}.map.summary"
    sta_sum="output_files/\${proj}.sta.summary"
  else
    fit_sum=\$(ls -t output_files/*.fit.summary 2>/dev/null | head -n 1 || true)
    map_sum=\$(ls -t output_files/*.map.summary 2>/dev/null | head -n 1 || true)
    sta_sum=\$(ls -t output_files/*.sta.summary 2>/dev/null | head -n 1 || true)
  fi

  local summary="\${fit_sum}"
  [[ ! -f "\$summary" ]] && summary="\${map_sum}"

  if [[ -z "\$summary" || ! -f "\$summary" ]]; then
    echo "Erro: nenhum relatório de compilação encontrado em output_files/." >&2
    echo "Compile primeiro com 'quartus compile'." >&2
    exit 1
  fi

  echo "=== Resumo de Recursos ==="
  cat "\$summary"

  if [[ -f "\$sta_sum" ]]; then
    echo ""
    echo "=== Timing (TimeQuest - Piores Slacks) ==="
    grep -E "^(Type|Slack|TNS)" "\$sta_sum" | head -n 12 || true
  fi
}

cmd_pins() {
  if [[ "\${1:-}" == "-h" || "\${1:-}" == "--help" ]]; then
    cat <<'HELP'
Uso:
  quartus pins                  Lista a pinagem da placa Terasic DE0 (EP3C16F484C6)
  quartus pins --apply [qsf]    Adiciona os pinos padrão da DE0 em um arquivo .qsf
HELP
    return 0
  fi

  if [[ "\${1:-}" == "--apply" ]]; then
    local qsf="\${2:-}"
    if [[ -z "\$qsf" ]]; then
      qsf=\$(ls -1 *.qsf 2>/dev/null | head -n 1 || true)
    fi
    if [[ -z "\$qsf" || ! -f "\$qsf" ]]; then
      echo "Erro: informe ou crie um arquivo .qsf no diretório atual." >&2
      exit 1
    fi
    if grep -q "Terasic DE0" "\$qsf" 2>/dev/null; then
      echo "[quartus] Pinagem da DE0 já aplicada em \$qsf."
      return 0
    fi
    echo "" >> "\$qsf"
    de0_pin_assignments >> "\$qsf"
    echo "[quartus] Pinagem da Terasic DE0 adicionada em \$qsf."
    return 0
  fi

  de0_pin_assignments
}

cmd_watch() {
  if [[ "\${1:-}" == "-h" || "\${1:-}" == "--help" || \$# -eq 0 ]]; then
    cat <<'HELP'
Uso: quartus watch <comando> [args...]

Descrição:
  Observa alterações em arquivos .v, .sv e .vhd no diretório atual e
  reexecuta automaticamente o comando informado ao salvar.

Exemplos:
  quartus watch compile
  quartus watch rtl booth_top.v
  quartus watch sim tb_booth.v
HELP
    [[ \$# -eq 0 ]] && exit 1
    return 0
  fi

  local subcmd=("\$@")
  echo "[quartus] Observando arquivos HDL em \$PWD (Ctrl+C para sair)..."
  echo "[quartus] Comando: quartus \${subcmd[*]}"

  if command -v inotifywait >/dev/null 2>&1; then
    while true; do
      inotifywait -q -e close_write,moved_to,create --include '\.(v|sv|vhd|vhdl)$' . >/dev/null 2>&1 || true
      echo ""
      echo "[quartus] Alteração detectada (\$(date +%H:%M:%S)). Executando..."
      "\$0" "\${subcmd[@]}" || true
    done
  else
    local last_state=""
    local curr_state=""
    last_state=\$(stat -c '%n:%Y' *.v *.sv *.vhd *.vhdl 2>/dev/null | sort | tr '\n' ' ')
    while true; do
      sleep 1
      curr_state=\$(stat -c '%n:%Y' *.v *.sv *.vhd *.vhdl 2>/dev/null | sort | tr '\n' ' ')
      if [[ "\$curr_state" != "\$last_state" ]]; then
        last_state="\$curr_state"
        echo ""
        echo "[quartus] Alteração detectada (\$(date +%H:%M:%S)). Executando..."
        "\$0" "\${subcmd[@]}" || true
      fi
    done
  fi
}

cmd_doctor() {
  if [[ "\${1:-}" == "-h" || "\${1:-}" == "--help" ]]; then
    cat <<'HELP'
Uso: quartus doctor

Descrição:
  Verifica a saúde da instalação: Quartus II 13.0 SP1, bibliotecas 32-bit,
  ModelSim-Altera, patches do Linux, regra udev do USB-Blaster, JTAG e
  ferramentas opcionais de RTL/simulação.
HELP
    return 0
  fi

  local ok="\033[1;32m[OK]\033[0m"
  local warn_tag="\033[1;33m[AVISO]\033[0m"
  local err_tag="\033[1;31m[ERRO]\033[0m"

  echo "=== Diagnóstico Quartus II 13.0 SP1 ==="
  if [[ -x "\$QUARTUS_BIN/quartus_sh" && -x "\$QUARTUS_BIN/quartus_pgm" ]]; then
    printf "%b Quartus II 13.0 SP1 em %s\n" "\$ok" "\$QUARTUS_ROOT"
  else
    printf "%b Quartus II 13.0 SP1 não encontrado em %s\n" "\$err_tag" "\$QUARTUS_ROOT"
  fi

  if ldconfig -p 2>/dev/null | grep -q "libc.so.6.*32bit\|/lib32/\|/lib/i386-linux-gnu/\|/usr/lib32/" || [[ -e /lib/ld-linux.so.2 || -e /lib32/ld-linux.so.2 ]]; then
    printf "%b Bibliotecas 32-bit detectadas\n" "\$ok"
  else
    printf "%b Bibliotecas 32-bit não detectadas\n" "\$err_tag"
  fi

  local msim_dir="\$(dirname "\$QUARTUS_ROOT")/modelsim_ase"
  if [[ -x "\$msim_dir/bin/vsim" ]]; then
    if grep -q 'vco="linux_rh60"' "\$msim_dir/vco" 2>/dev/null; then
      printf "%b ModelSim-Altera instalado, mas vco ainda usa linux_rh60\n" "\$warn_tag"
    else
      printf "%b ModelSim-Altera pronto (%s)\n" "\$ok" "\$msim_dir"
    fi
  else
    printf "%b ModelSim-Altera não instalado\n" "\$warn_tag"
  fi

  local qsim_tcl="\$QUARTUS_ROOT/common/tcl/apps/qsim/qsim_script_modified.tcl"
  if [[ -f "\$qsim_tcl" ]] && ! grep -qE '^[^#]*win32aloem' "\$qsim_tcl"; then
    printf "%b Patch Linux do simulador .vwf (qsim) aplicado\n" "\$ok"
  else
    printf "%b Patch Linux do qsim pendente\n" "\$warn_tag"
  fi

  if [[ -f /etc/udev/rules.d/51-usbblaster.rules ]]; then
    printf "%b Regra udev USB-Blaster configurada\n" "\$ok"
  else
    printf "%b Regra udev USB-Blaster ausente (/etc/udev/rules.d/51-usbblaster.rules)\n" "\$warn_tag"
  fi

  if [[ -x "\$QUARTUS_BIN/jtagconfig" ]] && "\$QUARTUS_BIN/jtagconfig" 2>/dev/null | grep -q "Blaster"; then
    printf "%b FPGA/USB-Blaster conectado via JTAG\n" "\$ok"
  else
    printf "%b Nenhum USB-Blaster conectado no momento\n" "\$warn_tag"
  fi

  local djs_render="\${DIGITALJS_RENDER:-\$HOME/.local/share/digitaljs/render.js}"
  if command -v yosys >/dev/null 2>&1; then
    printf "%b yosys instalado\n" "\$ok"
  else
    printf "%b yosys não instalado (use 'quartus install rtl')\n" "\$warn_tag"
  fi
  if [[ -f "\$djs_render" ]] && command -v node >/dev/null 2>&1; then
    printf "%b DigitalJS pronto\n" "\$ok"
  else
    printf "%b DigitalJS não instalado (use 'quartus install rtl')\n" "\$warn_tag"
  fi
  if command -v iverilog >/dev/null 2>&1 && command -v vvp >/dev/null 2>&1; then
    printf "%b iverilog/vvp instalados\n" "\$ok"
  else
    printf "%b iverilog/vvp não instalados\n" "\$warn_tag"
  fi
}

cmd_jtag() {
  if [[ "\${1:-}" == "-h" || "\${1:-}" == "--help" ]]; then
    cat <<'HELP'
Uso: quartus jtag [args...]

Descrição:
  Executa o 'jtagconfig' para listar os gravadores USB-Blaster e FPGAs detectadas.
HELP
    return 0
  fi
  ensure_quartus
  "\$QUARTUS_BIN/jtagconfig" "\$@"
}

cmd_gui() {
  if [[ "\${1:-}" == "-h" || "\${1:-}" == "--help" ]]; then
    cat <<'HELP'
Uso: quartus gui [arquivo.qpf]

Descrição:
  Abre a interface gráfica do Quartus II 13.0 SP1 Web Edition em segundo plano.
HELP
    return 0
  fi
  ensure_quartus
  nohup "\$QUARTUS_BIN/quartus" "\$@" >/dev/null 2>&1 &
}

case "\${1:-help}" in
  compile)   shift; cmd_compile "\$@" ;;
  rtl)       shift; cmd_rtl "\$@" ;;
  sim)       shift; cmd_sim "\$@" ;;
  report|stats) shift; cmd_report "\$@" ;;
  pins)      shift; cmd_pins "\$@" ;;
  watch)     shift; cmd_watch "\$@" ;;
  doctor)    shift; cmd_doctor "\$@" ;;
  install)   shift; cmd_install "\$@" ;;
  fpga)      shift; cmd_fpga "\$@" ;;
  clean)     shift; cmd_clean "\$@" ;;
  jtag)      shift; cmd_jtag "\$@" ;;
  gui)       shift; cmd_gui "\$@" ;;
  update)    shift; cmd_update "\$@" ;;
  uninstall) shift; cmd_uninstall "\$@" ;;
  sh)        ensure_quartus; shift; "\$QUARTUS_BIN/quartus_sh" "\$@" ;;
  pgm)       ensure_quartus; shift; "\$QUARTUS_BIN/quartus_pgm" "\$@" ;;
  -h|--help|help) usage ;;
  *)         ensure_quartus; nohup "\$QUARTUS_BIN/quartus" "\$@" >/dev/null 2>&1 & ;;
esac
EOF
  chmod +x "$target.tmp"
  mv -f "$target.tmp" "$target"
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

install_rtl_deps() {
  if [[ "$WITH_RTL" != true ]]; then
    return 0
  fi

  log "Instalando dependências de visualização RTL (yosys, nodejs/npm, netlistsvg, digitaljs)..."
  if ! command -v yosys >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    if command -v pacman >/dev/null 2>&1; then
      sudo pacman -S --needed --noconfirm yosys nodejs npm
    elif command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update && sudo apt-get install -y yosys nodejs npm
    elif command -v dnf >/dev/null 2>&1; then
      sudo dnf install -y yosys nodejs npm
    elif command -v zypper >/dev/null 2>&1; then
      sudo zypper install -y yosys nodejs npm
    else
      err "Gerenciador de pacotes não reconhecido. Instale 'yosys', 'nodejs' e 'npm' manualmente."
      exit 1
    fi
  fi

  local djs_dir="${HOME}/.local/share/digitaljs"
  mkdir -p "$djs_dir"
  if [[ ! -f "$djs_dir/package.json" ]]; then
    npm init -y --prefix "$djs_dir" >/dev/null 2>&1 || true
  fi
  npm install --prefix "$djs_dir" digitaljs yosys2digitaljs netlistsvg

  if [[ ! -f "$djs_dir/render.js" ]]; then
    cat > "$djs_dir/render.js" <<'RENDERJS'
#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const os = require('os');

const { process: y2dProcess } = require(path.join(__dirname, 'node_modules/yosys2digitaljs/dist/index.js'));
const { yosys2digitaljs, io_ui } = require(path.join(__dirname, 'node_modules/yosys2digitaljs/dist/core.js'));

const args = process.argv.slice(2);
let outFile = 'build/digitaljs.html';
let topModule = '';
const files = [];

for (let i = 0; i < args.length; i++) {
  if (args[i] === '-o' && i + 1 < args.length) outFile = args[++i];
  else if (args[i] === '--top' && i + 1 < args.length) topModule = args[++i];
  else files.push(args[i]);
}

if (files.length === 0) {
  console.error('Uso: render.js [-o out.html] [--top modulo] <arquivos.v...>');
  process.exit(1);
}

const distDir = path.join(__dirname, 'node_modules/digitaljs/dist');

async function main() {
  let circuitJson;
  if (topModule) {
    const tmpJson = path.join(os.tmpdir(), `y2d_${process.pid}_${Date.now()}.json`);
    const script = `read_verilog ${files.join(' ')}; prep -top ${topModule}; write_json ${tmpJson}`;
    execFileSync('yosys', ['-q', '-p', script], { stdio: 'inherit' });
    const yosysOut = JSON.parse(fs.readFileSync(tmpJson, 'utf8'));
    fs.unlinkSync(tmpJson);
    circuitJson = yosys2digitaljs(yosysOut, {});
    io_ui(circuitJson);
  } else {
    const res = await y2dProcess(files, process.cwd(), {});
    circuitJson = res.output;
    io_ui(circuitJson);
  }

  const title = topModule || path.basename(files[0], path.extname(files[0]));
  const html = `<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <title>DigitalJS - ${title}</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 16px; background: #fafafa; color: #222; }
    .toolbar { display: flex; gap: 8px; align-items: center; margin-bottom: 12px; flex-wrap: wrap; }
    button { padding: 6px 12px; cursor: pointer; }
    #paper { background: #fff; border: 1px solid #ddd; border-radius: 6px; padding: 8px; overflow: auto; }
    #iopanel, #monitor { margin-top: 12px; }
  </style>
  <script defer="defer" src="file://${distDir}/main.js"></script>
</head>
<body>
  <div class="toolbar">
    <button name="start" type="button">▶ Start</button>
    <button name="stop" type="button">⏹ Stop</button>
    <label><input name="fixed" type="checkbox"> Fixed Mode</label>
  </div>
  <div id="paper"></div>
  <div id="iopanel"></div>
  <div id="monitor"></div>
  <script>
    const CIRCUIT_JSON = ${JSON.stringify(circuitJson)};
    document.addEventListener('DOMContentLoaded', () => {
      const start = $('button[name=start]');
      const stop = $('button[name=stop]');
      const papers = {};
      const fixed = (val) => Object.values(papers).forEach(p => p.fixed(val));
      const circuit = new digitaljs.Circuit(CIRCUIT_JSON);
      const monitor = new digitaljs.Monitor(circuit);
      new digitaljs.MonitorView({ model: monitor, el: $('#monitor') });
      new digitaljs.IOPanelView({ model: circuit, el: $('#iopanel') });
      circuit.on('new:paper', (paper) => { paper.fixed($('input[name=fixed]').prop('checked')); papers[paper.cid] = paper; });
      circuit.on('remove:paper', (paper) => delete papers[paper.cid]);
      circuit.on('changeRunning', () => { start.prop('disabled', circuit.running); stop.prop('disabled', !circuit.running); });
      circuit.displayOn($('#paper'));
      fixed($('input[name=fixed]').prop('checked'));
      circuit.start();
      start.on('click', () => circuit.start());
      stop.on('click', () => circuit.stop());
      $('input[name=fixed]').change(function () { fixed($(this).prop('checked')); });
    });
  </script>
</body>
</html>`;

  fs.mkdirSync(path.dirname(outFile), { recursive: true });
  fs.writeFileSync(outFile, html, 'utf8');
  console.log(\`Gerado \${outFile}\`);
}

main().catch((err) => { console.error(err.message || err); process.exit(1); });
RENDERJS
    chmod +x "$djs_dir/render.js"
  fi
}

main() {
  check_32bit_deps
  install_quartus
  install_rtl_deps
  install_cli_wrapper
  install_desktop_entry
  setup_udev_rules
  check_path
  log "Tudo pronto! Teste com: quartus help"
}

main
