#!/usr/bin/env bash

###############################################################################
# SCRIPT      : temp_control.sh
# DESCRIPTION : Controla la temperatura del procesador de una Raspberry Pi
# AUTHOR      : José A. G. (Adaptado)
# CREATED     : 2026-10-20
# VERSION     : 2.1.0
# LICENSE     : MIT
# REQUIREMENTS: Bash 4.0+
# USAGE       : ./temp_control.sh [argumentos]
###############################################################################

# ==============================================================================
# 1. CONFIG
# ==============================================================================
set -Eeuo pipefail

# Rutas
LOG_DIR="$HOME/logs"
DIR_ALERTA="$LOG_DIR/temp_alertas"
FILE_LOG="$LOG_DIR/temp.log"
FECHA=$(date +'%F_%T')
FILE_ALERTA="$DIR_ALERTA/$FECHA.log"

# Valores por defecto de temperatura (ºC)
DEFAULT_LIMIT_LOG=60
DEFAULT_LIMIT_RESTART=75
DEFAULT_LIMIT_SHUTDOWN=80

# ==============================================================================
# 2. FUNCTIONS
# ==============================================================================

init_dirs() {
    mkdir -p "$DIR_ALERTA"
}

get_temp() {
    # Método estándar de Linux moderno (devuelve miligrados, por lo que dividimos entre 1000)
    local raw_temp
    raw_temp=$(cat /sys/class/thermal/thermal_zone0/temp)
    printf "%s" "$((raw_temp / 1000))"
}

usage() {
    printf "Uso: %s [hipt] [-l TEMP] [-s TEMP] [-r TEMP]\n" "${0##*/}"
    printf "  -h          Muestra la ayuda\n"
    printf "  -i          Muestra información sobre procesos y temperaturas\n"
    printf "  -l <TEMP>   Temperatura mínima a la que se anota en el log\n"
    printf "  -p          Muestra el registro de temperatura y la última ALERTA\n"
    printf "  -r <TEMP>   Reinicia el sistema al alcanzar la temperatura marcada\n"
    printf "  -s <TEMP>   Temperatura a la que se apaga la Rpi\n"
    printf "  -t          Imprime en pantalla la temperatura actual\n"
    printf "  (Sin args)  Ejecuta usando los valores por defecto configurados.\n"
    printf "  (crontab)   */5 * * * * /home/josea/bin/temp_control.sh >/dev/null 2>&1\n"
}
alerta_log() {
    printf "\nUSO DEL PROCESADOR:\n"
    ps aux k-pcpu | head -5
    printf "\nUSO DE MEMORIA:\n"
    ps aux k-pmem | head -5
    printf "\nUSO TOTAL DE MEMORIA:\n"
    free
}

alerta_info() {
    printf "\nTOP 5 PROCESOS (CPU):\n"
    ps -eo pid,%cpu,%mem,comm --sort=-%cpu | head -n 6 | awk '{printf "%-8s %-6s %-6s %-.40s\n", $1, $2, $3, $4}'
    
    printf "\nTOP 5 PROCESOS (MEM):\n"
    ps -eo pid,%cpu,%mem,comm --sort=-%mem | head -n 6 | awk '{printf "%-8s %-6s %-6s %-.40s\n", $1, $2, $3, $4}'
    
    printf "\nMEMORIA RAM (MB):\n"
    free -m | awk 'NR==1 || NR==2 {print $1, $2, $3, $4, $7}' | column -t
}

imprimir_registro() {
    printf "\n%s\nÚltimos registros por encima del límite:\n" "$FILE_LOG"
    if [[ -f "$FILE_LOG" ]]; then
        tail -n 10 "$FILE_LOG"
    else
        printf "Aún no hay registros.\n"
    fi
}

imprimir_alerta() {
    printf "\nÚltima ALERTA:\n"
    local ultima_alerta
    ultima_alerta=$(find "$DIR_ALERTA" -type f -name "*.log" -print -quit | sort -r | head -n 1 || true)
    
    if [[ -n "$ultima_alerta" ]]; then
        cat "$ultima_alerta"
    else
        printf "No hay alertas guardadas.\n"
    fi
}

info() {
    alerta_info
    imprimir_registro
    
    local temp=$1
    printf "\n--- ESTADO DEL HARDWARE ---\n"
    printf "Fecha y hora: %s\n" "$FECHA"
    printf "Temperatura : %s ºC\n" "$temp"
    
    # Se usa sudo para saltar las restricciones de acceso al hardware del sistema operativo
    printf "Voltaje     : "
    sudo vcgencmd measure_volts | cut -d= -f2 || printf "No disponible\n"
    
    printf "Throttled   : "
    sudo vcgencmd get_throttled | cut -d= -f2 || printf "No disponible\n"
    printf "(0x0 = Todo correcto. Otros valores indican alertas de energía o temperatura)\n"
}

parse_args() {
    local temp=$1
    shift # Quitamos la temperatura de la lista para procesar los argumentos $@

    # Si se ejecuta sin argumentos, evaluamos usando los valores de CONFIG
    if [[ $# -eq 0 ]]; then
        if [[ "$temp" -gt "$DEFAULT_LIMIT_SHUTDOWN" ]]; then
            printf "%s -> %s\n" "$FECHA" "$temp"
            alerta_log >> "$FILE_ALERTA"
            sudo shutdown -h now
            exit 3
        elif [[ "$temp" -gt "$DEFAULT_LIMIT_RESTART" ]]; then
            printf "%s -> %s\n" "$FECHA" "$temp"
            printf "ALERTA:\n+ INFO en %s\n" "$FILE_ALERTA" >> "$FILE_ALERTA"
            alerta_log >> "$FILE_ALERTA"
            sudo shutdown -r now
            exit 2
        elif [[ "$temp" -gt "$DEFAULT_LIMIT_LOG" ]]; then
            printf "Temperatura Actual del procesador:\n%s -> %s\n" "$FECHA" "$temp" >> "$FILE_LOG"
        fi
        exit 0
    fi

    # Lógica de argumentos personalizados
    while getopts "hil:s:pr:t" option; do
        case "${option}" in
            h) usage ;;
            i) info "$temp" ; exit 0 ;;
            l)
                if [[ "$temp" -gt "${OPTARG}" ]]; then
                    printf "Temperatura Actual del procesador:\n%s -> %s\n" "$FECHA" "$temp" >> "$FILE_LOG"
                fi
                exit 0
                ;;
            p) imprimir_registro ; imprimir_alerta ;;
            r)
                if [[ "$temp" -gt "${OPTARG}" ]]; then
                    printf "%s -> %s\n" "$FECHA" "$temp"
                    printf "ALERTA:\n+ INFO en %s\n" "$FILE_ALERTA" >> "$FILE_ALERTA"
                    alerta_log >> "$FILE_ALERTA"
                    sudo shutdown -r now
                    exit 2
                fi
                exit 0
                ;;
            s)
                if [[ "$temp" -gt "${OPTARG}" ]]; then
                    printf "%s -> %s\n" "$FECHA" "$temp"
                    alerta_log >> "$FILE_ALERTA"
                    sudo shutdown -h now
                    exit 3
                fi
                exit 0
                ;;
            t) printf "Temperatura actual: %s ºC\n" "$temp" ;;
            \?) printf "ERROR: argumento no válido\n" ; usage ; exit 1 ;;
        esac
    done
}

# ==============================================================================
# 3. MAIN
# ==============================================================================

main() {
    init_dirs
    local temp
    temp=$(get_temp)

    # Pasamos la temperatura actual y todos los argumentos recibidos al ejecutar el script
    parse_args "$temp" "$@"
}

main "$@"