# Quartus II 13.0 SP1 Installer & CLI

Script agnóstico de distro para instalar o **Altera Quartus II 13.0 SP1 Web Edition** localmente no Linux e disponibilizar o comando `quartus` no `PATH`.

## Instalação rápida

```bash
curl -fsSL https://raw.githubusercontent.com/gbtaffarel/quartus-installer/main/install-quartus13.sh | bash
```

Para passar opções (por exemplo, configurar regras `udev` para o USB-Blaster e remover o `.iso` após instalar):

```bash
curl -fsSL https://raw.githubusercontent.com/gbtaffarel/quartus-installer/main/install-quartus13.sh | bash -s -- --setup-udev --clean-iso
```

### Opções disponíveis
- `--iso /caminho/para/Quartus-web-13.0.1.232.iso` — usa um ISO já baixado
- `--clean-iso` — remove o ISO após instalar
- `--setup-udev` — configura permissões do USB-Blaster em `/etc/udev/rules.d/` (usa `sudo`)
- `--with-rtl` — instala `yosys`, `netlistsvg` e `DigitalJS` para o comando `quartus rtl` (usa `sudo` apenas para `yosys`/`nodejs`/`npm`)
- `--all-devices` — inclui MAX, Arria e Cyclone V além de Cyclone II/III/IV
- `--install-dir DIR` — diretório de instalação (padrão: `~/altera/13.0sp1`)
- `--bin-dir DIR` — diretório do executável `quartus` (padrão: `~/.local/bin`)

## Uso do comando `quartus`

```bash
# Compilar criando um projeto automaticamente (Cyclone III EP3C16F484C6 por padrão)
quartus compile booth_top booth_top.v booth_control.v booth_datapath.v

# Compilar um projeto .qpf já existente no diretório atual
quartus compile

# Visualizar o esquemático RTL (automático: DigitalJS -> Yosys+netlistsvg -> Quartus)
quartus rtl booth_top.v
# Instalar dependências de visualização RTL (yosys, netlistsvg e DigitalJS):
quartus install rtl
# Ou escolher explicitamente o visualizador:
quartus rtl --digitaljs booth_top.v
quartus rtl --svg booth_top.v
quartus rtl --quartus booth_top.v

# Enviar o .sof gerado para a FPGA via USB-Blaster
quartus fpga
# ou especificando o arquivo:
quartus fpga output_files/multiplicador.sof

# Verificar conexão JTAG
quartus jtag

# Abrir interface gráfica
quartus gui

# Atualizar o utilitário quartus pelo GitHub
quartus update

# Desinstalar Quartus II 13.0 SP1, comando e atalho .desktop
quartus uninstall
```

Para alterar o dispositivo padrão:
```bash
export QUARTUS_FAMILY="Cyclone II"
export QUARTUS_DEVICE="EP2C35F672C6"
```
