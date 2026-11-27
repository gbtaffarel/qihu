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
  local script_dir=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi
  local local_cli="$script_dir/bin/quartus"
  local remote_cli="${QUARTUS_CLI_URL:-https://raw.githubusercontent.com/gbtaffarel/quartus-installer/main/bin/quartus}"

  log "Instalando comando 'quartus' em $target..."
  if [[ -n "$script_dir" && -f "$local_cli" ]]; then
    cp "$local_cli" "$target.tmp"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "$remote_cli" -o "$target.tmp"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$target.tmp" "$remote_cli"
  else
    err "Não foi possível obter bin/quartus (nem local nem via curl/wget)."
    exit 1
  fi

  sed -i "s|^QUARTUS_INSTALL_DIR=.*|QUARTUS_INSTALL_DIR=\"\${QUARTUS_INSTALL_DIR:-$INSTALL_DIR}\"|; s|^QUARTUS_BIN_DIR=.*|QUARTUS_BIN_DIR=\"\${QUARTUS_BIN_DIR:-$BIN_DIR}\"|" "$target.tmp"
  chmod +x "$target.tmp"
  mv -f "$target.tmp" "$target"
  ln -sf quartus "$BIN_DIR/qihu"
}

# ------------------------------------------------------------------------------
# 4. Desktop entry + PATH + optional udev rules
# ------------------------------------------------------------------------------
install_completions() {
  local bash_comp_dir="${HOME}/.local/share/bash-completion/completions"
  local zsh_comp_dir="${HOME}/.local/share/zsh/site-functions"
  mkdir -p "$bash_comp_dir" "$zsh_comp_dir"

  cat > "$bash_comp_dir/quartus" <<'BASHCOMP'
_quartus_completions() {
  local cur prev subcmd
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  subcmd="${COMP_WORDS[1]:-}"

  local cmds="compile rtl sim fpga report stats pins watch doctor install clean jtag gui update uninstall sh pgm help"

  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
    return 0
  fi

  case "$subcmd" in
    compile)
      if [[ "$prev" == "--board" ]]; then
        COMPREPLY=( $(compgen -W "de0" -- "$cur") )
      elif [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "--board -h --help" -- "$cur") )
      else
        COMPREPLY=( $(compgen -f -X '!*.@(v|sv|vhd|vhdl|qpf)' -- "$cur") )
      fi
      ;;
    rtl)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "--digitaljs --svg --yosys --quartus --viewer --auto -h --help" -- "$cur") )
      else
        COMPREPLY=( $(compgen -f -X '!*.@(v|sv)' -- "$cur") )
      fi
      ;;
    sim)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "-w --wave --modelsim -h --help" -- "$cur") )
      else
        COMPREPLY=( $(compgen -f -X '!*.@(v|sv)' -- "$cur") )
      fi
      ;;
    fpga)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "-r --recompile -p --permanent -h --help" -- "$cur") )
      else
        COMPREPLY=( $(compgen -f -X '!*.@(sof|pof)' -- "$cur") )
      fi
      ;;
    pins)
      if [[ "$prev" == "--apply" ]]; then
        COMPREPLY=( $(compgen -f -X '!*.qsf' -- "$cur") )
      else
        COMPREPLY=( $(compgen -W "--apply -h --help" -- "$cur") )
      fi
      ;;
    install)
      COMPREPLY=( $(compgen -W "rtl -h --help" -- "$cur") )
      ;;
    watch)
      if [[ $COMP_CWORD -eq 2 ]]; then
        COMPREPLY=( $(compgen -W "compile rtl sim fpga report" -- "$cur") )
      else
        COMPREPLY=( $(compgen -f -- "$cur") )
      fi
      ;;
    uninstall)
      COMPREPLY=( $(compgen -W "-y --yes -h --help" -- "$cur") )
      ;;
    *)
      COMPREPLY=( $(compgen -f -- "$cur") )
      ;;
  esac
}
complete -F _quartus_completions quartus qihu
BASHCOMP

  cat > "$zsh_comp_dir/_quartus" <<'ZSHCOMP'
#compdef quartus qihu

_quartus() {
  local -a cmds
  cmds=(
    'compile:Compila o projeto (.qpf ou arquivos Verilog/VHDL)'
    'rtl:Visualiza o esquemático RTL'
    'sim:Simula testbench com iverilog/GTKWave ou ModelSim'
    'fpga:Grava bitstream (.sof/.pof) na FPGA via USB-Blaster'
    'report:Resumo de recursos e timing da compilação'
    'stats:Alias para report'
    'pins:Lista ou aplica pinagem da placa DE0'
    'watch:Reexecuta comando ao salvar arquivos HDL'
    'doctor:Verifica saúde do ambiente Quartus/ModelSim/RTL'
    'install:Instala componentes extras (rtl)'
    'clean:Remove arquivos gerados pela compilação'
    'jtag:Verifica dispositivos JTAG conectados'
    'gui:Abre a interface gráfica do Quartus II 13.0 SP1'
    'update:Atualiza o utilitário quartus pelo GitHub'
    'uninstall:Remove o Quartus II 13.0 SP1 e o utilitário'
    'help:Mostra ajuda'
  )

  if (( CURRENT == 2 )); then
    _describe 'comando' cmds
    return
  fi

  case "$words[2]" in
    compile)   _arguments '--board[Placa alvo]:board:(de0)' '(-h --help)'{-h,--help}'[Ajuda]' '*:arquivo:_files -g "*.(v|sv|vhd|vhdl|qpf)"' ;;
    rtl)       _arguments '--digitaljs[HTML interativo]' '--svg[SVG via Yosys]' '--quartus[Quartus GUI]' '--auto[Automático]' '(-h --help)'{-h,--help}'[Ajuda]' '*:arquivo:_files -g "*.(v|sv)"' ;;
    sim)       _arguments '(-w --wave)'{-w,--wave}'[Abrir GTKWave]' '--modelsim[Usar ModelSim]' '(-h --help)'{-h,--help}'[Ajuda]' '*:arquivo:_files -g "*.(v|sv)"' ;;
    fpga)      _arguments '(-r --recompile)'{-r,--recompile}'[Recompilar antes]' '(-p --permanent)'{-p,--permanent}'[Gravar .pof na flash]' '(-h --help)'{-h,--help}'[Ajuda]' '*:bitstream:_files -g "*.(sof|pof)"' ;;
    pins)      _arguments '--apply[Aplicar em .qsf]:qsf:_files -g "*.qsf"' '(-h --help)'{-h,--help}'[Ajuda]' ;;
    install)   _values 'componente' 'rtl' ;;
    watch)     (( CURRENT == 3 )) && _values 'comando' compile rtl sim fpga report || _files ;;
    uninstall) _arguments '(-y --yes)'{-y,--yes}'[Sem confirmação]' '(-h --help)'{-h,--help}'[Ajuda]' ;;
    *)         _files ;;
  esac
}

_quartus "$@"
ZSHCOMP
}

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
    #iopanel {
      margin-top: 12px;
      display: flex;
      flex-wrap: wrap;
      gap: 10px 16px;
      align-items: center;
      background: #fff;
      border: 1px solid #ddd;
      border-radius: 6px;
      padding: 10px 12px;
    }
    #iopanel > div, #iopanel > label, #iopanel > span {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      margin: 0;
      padding: 4px 8px;
      background: #f5f5f5;
      border: 1px solid #e2e2e2;
      border-radius: 4px;
    }
    #monitor { margin-top: 12px; }
    .shortcuts { margin-left: auto; color: #666; font-size: 0.85em; }
  </style>
  <script defer="defer" src="file://${distDir}/main.js"></script>
</head>
<body>
  <div class="toolbar">
    <button name="start" type="button">▶ Start</button>
    <button name="stop" type="button">⏹ Stop</button>
    <label><input name="fixed" type="checkbox"> Fixed Mode</label>
    <span class="shortcuts">Atalhos: <b>Espaço</b> Start/Stop · <b>F</b> Fixed · <b>1-9</b> Entradas · Duplo clique no módulo para abrir</span>
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
      document.addEventListener('keydown', (e) => {
        const tag = (e.target && e.target.tagName) ? e.target.tagName.toUpperCase() : '';
        if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') {
          if (e.key === 'Escape') e.target.blur();
          return;
        }
        if (e.code === 'Space') {
          e.preventDefault();
          if (circuit.running) circuit.stop();
          else circuit.start();
        } else if (e.key === 'f' || e.key === 'F') {
          e.preventDefault();
          const cb = $('input[name=fixed]');
          cb.prop('checked', !cb.prop('checked')).trigger('change');
        } else if (e.key >= '1' && e.key <= '9') {
          const idx = parseInt(e.key, 10) - 1;
          const inputs = $('#iopanel input:not([disabled]), #iopanel button:not([disabled])');
          const el = inputs.eq(idx);
          if (el.length) {
            e.preventDefault();
            if (el.attr('type') === 'checkbox' || el.is('button')) el.trigger('click');
            else el.focus().select();
          }
        }
      });
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
  install_completions
  install_desktop_entry
  setup_udev_rules
  check_path
  log "Tudo pronto! Teste com: quartus help"
}

main
