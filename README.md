# Quartus I Hate You

Script para instalar o **Altera Quartus II 13.0 SP1 Web Edition** localmente no Linux e disponibilizar o comando `qihu` no `PATH`.

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

## Uso do comando `quartus` (ou `qihu`)

> Dica: o comando também fica disponível pelo alias **`quartus`** (ex.: `quartus compile`, `quartus fpga`, `quartus rtl ...`).

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
# Recompilar o projeto atual e enviar para a FPGA:
quartus fpga --recompile
# Gravar na memória flash não-volátil (.pof via Active Serial):
quartus fpga --permanent output_files/projeto.pof
# ou especificando o arquivo:
quartus fpga output_files/multiplicador.sof

# Simular testbench com iverilog/GTKWave (ou --modelsim)
quartus sim --wave tb_booth.v

# Ver resumo de recursos e timing da última compilação
quartus report

# Consultar ou aplicar pinagem padrão da placa Terasic DE0
quartus pins
quartus pins --apply projeto.qsf

# Recompilar ou atualizar RTL automaticamente ao salvar arquivos .v/.sv/.vhd
quartus watch compile

# Verificar saúde do ambiente (libs, ModelSim, udev, JTAG, RTL)
quartus doctor

# Limpar arquivos gerados pela compilação (mantém .v/.vhd/.qpf/.qsf)
quartus clean

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

## Licença

O instalador e o utilitário CLI são distribuídos sob a licença [MIT](LICENSE). Os binários do **Quartus II Web Edition** e **ModelSim-Altera** pertencem à Altera/Intel e seguem seus respectivos termos de uso.
